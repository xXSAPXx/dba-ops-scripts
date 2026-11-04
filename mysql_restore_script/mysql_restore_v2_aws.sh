#!/bin/bash

# =================================================================================================================================
# BEFORE THE FIRST RUN ON A SERVER: what to set up and what to decide (details in the notes and at the variables below).
#
# Set up:
#  - S3_BUCKET: the bucket and folder of the backups to restore.
#  - BINLOG_S3_BUCKET: the bucket and folder of the binlog backups (mysql_binlog_backup_v2_aws.sh), to fetch binlogs.
#  - ENCRYPTION_KEY_SECRET: the AWS Secrets Manager secret the backups were encrypted with.
#  - The server's IAM role: s3:GetObject and s3:ListBucket on the bucket folders, secretsmanager:GetSecretValue on the secret.
#  - Installed: Percona XtraBackup for the MySQL version of the backups (8.4 for MySQL 8.4), and the AWS CLI v2. To replay binlogs: mysqlbinlog and mysql.
#  - DATA_DIR: this server's datadir, on a disk with room for the whole database (decompressed). MySQL runs as the systemd service mysqld.
#  - The mysqld service starts mysqld with $MYSQLD_OPTS (Percona's does), and /etc/sysconfig/mysql does not set MYSQLD_OPTS: the script starts MySQL closed with it.
#  - INCREMENTAL_DIR: a folder on a disk with room for one incremental backup (decompressed).
#  - SHELL_RESTORE_DIR: a folder on a disk with room for one MySQL Shell dump, to fetch MySQL Shell archives.
#  - BINLOG_RESTORE_DIR: a folder on a disk with room for the binlogs to replay, to fetch binlogs.
#  - PREPARE_MEMORY: about half of MemAvailable, checked with MySQL stopped. xtrabackup can't use huge pages reserved for MySQL (see the variable below).
#  - The relaylog, doublebuff, binlog and log folders the script creates in DATA_DIR: they must match this server's my.cnf.
#  - MySQL login over the local socket: mysql_config_editor set --login-path=local, or /root/.my.cnf. While MySQL is closed, TCP (127.0.0.1) does not work.
#  - Run it as root.
#
# Decide:
#  - Which backups: the full backup, then its incremental backups up to the moment to restore (see the usage: aws s3 ls).
#    For a moment between two backups: the last backup that ENDED before it, then the binlogs. The backup names show when a backup started, but its data reaches its end.
#  - Restoring on the same server: the restore deletes the binlogs in the datadir, also those not in the bucket yet (up to one cron interval of changes).
#    To keep them: run mysql_binlog_backup_v2_aws.sh --continuous_binlog_backup first or, with MySQL down, copy them off the datadir by hand.
#  - Restoring to an older point: the new binlog chain can reach binlog names the old chain already has in the bucket. Its upload then fails (PreconditionFailed),
#    and a later --fetch_binlogs refuses two sequences with the same numbers. Move the old chain's binlogs from those numbers on out of the server's folder.
#  - Or a MySQL Shell archive: what to load from it once it is fetched (the whole instance, one database, one table).
#  - After the restore: MySQL is CLOSED to clients until a person runs systemctl restart mysqld. Check the data and replay any binlogs first.
#  - After the restore: a new full backup and a new binlog chain, and what clients and replicas need for the new server_uuid
#    and TLS certificates (the reminders at the end of the run).
# =================================================================================================================================

# -E: the ERR trap set before mysqld is stopped also covers the functions (restore_backup):
set -Eeuo pipefail

# No core dumps: a crashing xbstream would write its memory, and the encryption key in it, to disk (systemd-coredump):
ulimit -c 0

# Script for restoring MySQL from the XtraBackup backups in the S3 bucket. (Version 2, AWS)
# The AWS version of mysql_restore.sh, for the backups of mysql_backup_v3_aws.sh: encrypted, full or incremental (a chain).
# 1) Checks what it can before it stops MySQL: the backup names and their order, that they are in the bucket, and the encryption key.
# 2) Restores each backup with one command: streamed from the bucket, then decrypted and decompressed on the way (xbstream),
#    so nothing encrypted is stored on disk. The full backup goes straight into the datadir, each incremental into INCREMENTAL_DIR.
# 3) Prepares each backup with a separate command (--use-memory=PREPARE_MEMORY), with --apply-log-only for all but the last one.
# 4) Restores the incremental backups one at a time: extract, apply, delete. INCREMENTAL_DIR never holds more than one.
# 5) Reads the encryption key from AWS Secrets Manager into a file on the RAM disk (/dev/shm), removed when the script ends.
# 6) Logs the whole run to LOG_FILE, and ends with the total duration and what changed with the restore.
# 7) Deletes the backup chains of this server: the incremental one (BACKUP_CHAIN_STATE), so the next incremental backup fails until a full backup
#    runs, and the binlog one (BINLOG_CHAIN_STATE), so the next binlog backup fails until a person starts a new chain.
# 8) A MySQL Shell archive (full-instance-backup-<time>.tar.xbcrypt) is only fetched: streamed from the bucket, decrypted and unpacked into
#    SHELL_RESTORE_DIR with one command. MySQL is not touched: a DBA then loads what is needed with util.loadDump (the script prints how).
# 9) After every prepare it prints the binary log position the data reached. A later moment needs the binlogs from that position on.
# 10) MySQL comes up CLOSED after an XtraBackup restore, so nothing can write before a binlog replay or the DBA's checks: only the local socket
#     works, with no replication and no scheduled events. It stays closed until a person runs: systemctl restart mysqld
# 11) --fetch_binlogs <server>, after an XtraBackup restore, only fetches the binlogs: streamed from the bucket and decrypted into BINLOG_RESTORE_DIR,
#     from the position the data reached. A DBA then replays them by hand with mysqlbinlog (the script prints how), up to the chosen moment.
# WARNING: an XtraBackup restore stops MySQL and deletes everything in the datadir, and MySQL stays closed to clients until it is restarted by hand.

# === Colors ===
GREEN="\e[32m"
CYAN="\e[36m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

# === Log file ===
LOG_FILE="/opt/restore_script.log"

# === Settings ===
# Set the S3 bucket and folder of the backups before the first run (in the aws-dba-labs lab: terraform output backup_s3_prefix):
S3_BUCKET="s3://BUCKET/mysql"
# The AWS Secrets Manager secret with the encryption key of the backups (32 characters):
ENCRYPTION_KEY_SECRET="mysql-single/backup-encryption-key"
DATA_DIR="/var/lib/mysql"
# Each incremental backup is extracted here, applied to DATA_DIR, and deleted before the next one:
INCREMENTAL_DIR="/backup/restore_incremental"
# A MySQL Shell archive is unpacked into a folder here. Not directly in /backup: the backup script's cleanup deletes full-instance-backup*
# folders there that are over a day old, and tar restores the folder's old date, so the next backup run would delete it:
SHELL_RESTORE_DIR="/backup/restore_shell"
# The binlogs of mysql_binlog_backup_v2_aws.sh: <this folder>/<server name>/<date>/<binary log>.xbcrypt
BINLOG_S3_BUCKET="$S3_BUCKET/binlog_backups"
# The binlogs are decrypted into this folder. They can't be streamed to the replay: mysqlbinlog must read all of them in one process, as files:
BINLOG_RESTORE_DIR="/backup/restore_binlogs"
# Memory for the prepare (xtrabackup's default is only 100M). Too much can OOM the server: xtrabackup can't use huge pages reserved for MySQL (vm.nr_hugepages).
# Check with MySQL stopped: grep -E 'HugePages_Total|Hugepagesize|MemAvailable' /proc/meminfo. Then use about half of MemAvailable:
PREPARE_MEMORY="2G"
# The incremental backup chain of mysql_backup_v3_aws.sh on this server. The restore deletes it: an incremental from the old chain
# would succeed without an error but miss changes, so --xtrabackup_incremental fails instead until a full backup starts a new chain:
BACKUP_CHAIN_STATE="/opt/scripts/mysql_backup.state"
# The binlog chain of mysql_binlog_backup_v2_aws.sh on this server. The restore deletes it: the restored server's new binlogs would go into the old
# chain without an error (tested), so --continuous_binlog_backup fails instead until a person starts a new chain with --init_binlog_chain:
BINLOG_CHAIN_STATE="/opt/scripts/mysql_binlog_backup.state"
# Set to the key file on the RAM disk once the key is read:
KEY_FILE=""

# === Backup arguments: the full backup, then its incremental backups in order (names as aws s3 ls shows them) ===
FULL_BACKUP="${1:-}"
INCREMENTAL_BACKUPS=("${@:2}")
# The file name decides the path: for a MySQL Shell archive, this is the folder it unpacks to (empty for an XtraBackup restore):
DUMP_FOLDER=""
[[ "$FULL_BACKUP" == full-instance-backup-*.tar.xbcrypt ]] && DUMP_FOLDER="$SHELL_RESTORE_DIR/${FULL_BACKUP%.tar.xbcrypt}-mysql-shell"
# --fetch_binlogs <server> is the third path: the server the backup came from, whose binlogs are fetched (empty for the other two paths):
SOURCE_SERVER=""
if [ "$FULL_BACKUP" = "--fetch_binlogs" ]; then
    SOURCE_SERVER="${2:-}"
    INCREMENTAL_BACKUPS=()
fi

if [ -z "$FULL_BACKUP" ] || [ "$*" = "--fetch_binlogs" ]; then
    echo
    echo -e "${RED}╰┈➤ Error: Missing backup argument.${RESET}"
    echo "======================================================================================================================"
    echo
    echo -e " ${CYAN}--Example Usage:${RESET}         | $0 2026-10-31-130108-dbfull.xbstream"
    echo
    echo -e " ${CYAN}--With Incrementals:${RESET}     | $0 2026-10-31-130108-dbfull.xbstream \\"
    echo -e "                          |     2026-10-31-131934-dbincr.xbstream 2026-10-31-132156-dbincr.xbstream"
    echo -e "                          | The full backup first, then its incremental backups in order, up to the one to restore."
    echo
    echo -e " ${CYAN}--MySQL Shell Archive:${RESET}   | $0 full-instance-backup-2026-10-31-130108.tar.xbcrypt"
    echo -e "                          | Only fetched into $SHELL_RESTORE_DIR. MySQL is not touched: you choose what to load."
    echo
    echo -e " ${CYAN}--Fetch Binlogs:${RESET}         | $0 --fetch_binlogs <server the backup came from>"
    echo -e "                          | After an XtraBackup restore, for a moment later than the backup. Only fetched into $BINLOG_RESTORE_DIR:"
    echo -e "                          | you replay them by hand (the script prints how). Servers: aws s3 ls $BINLOG_S3_BUCKET/"
    echo
    echo -e " ${CYAN}--Check Latest Backups:${RESET}  | aws s3 ls $S3_BUCKET/ --human-readable | grep -E 'xbstream|xbcrypt'"
    echo
    echo -e " ${YELLOW}--After a Restore:${RESET}       | MySQL is CLOSED to clients until you run: systemctl restart mysqld"
    echo
    echo "======================================================================================================================"
    exit 1
fi


# Function to stop the restore with an error:
fail(){
    echo -e "${RED}╰┈➤ Error: $1${RESET}"
    exit 1
}


# Function to restore one backup into a folder with one command: streamed from the bucket, then decrypted and decompressed by xbstream.
# xbstream 8.4 prints "encryption: both encryption key and key file specified." a few times: harmless, only the key file is given:
restore_backup(){
    aws s3 cp "$S3_BUCKET/$1" - | xbstream -x -C "$2" --parallel=16 --decompress --decompress-threads=16 \
        --decrypt=AES256 --encrypt-key-file="$KEY_FILE" --encrypt-threads=16 --verbose
}


# Function to print the binary log position the data reached, and when that backup ended. Each prepare copies xtrabackup_binlog_info and
# xtrabackup_info from the incremental backup, so they describe the last backup applied. Without them (binlogs off) there is nothing to print:
show_binlog_position(){
    [ -f "$DATA_DIR/xtrabackup_binlog_info" ] || return 0
    local BINLOG_FILE BINLOG_POSITION
    read -r BINLOG_FILE BINLOG_POSITION _ < "$DATA_DIR/xtrabackup_binlog_info"
    echo -e "${CYAN}$1: $BINLOG_FILE, position $BINLOG_POSITION (backup ended $(sed -n 's/^end_time = //p' "$DATA_DIR/xtrabackup_info"))${RESET}"
}


echo
echo "======================================================================================================================"
echo
if [ -n "$SOURCE_SERVER" ]; then
    echo -e "${GREEN} Fetching the binlogs of $SOURCE_SERVER (MySQL is not touched)${RESET}"
elif [ -n "$DUMP_FOLDER" ]; then
    echo -e "${GREEN} Fetching the MySQL Shell archive (MySQL is not touched):${RESET} $FULL_BACKUP"
else
    echo -e "${GREEN} Starting MySQL restore using Xtrabackup:${RESET} $FULL_BACKUP + ${#INCREMENTAL_BACKUPS[@]} incremental backup(s)"
fi
echo
echo -e "${CYAN} All output is being logged to:${RESET} $LOG_FILE"
echo
echo "======================================================================================================================"
echo

exec > >(tee "$LOG_FILE") 2>&1

START_TIME="$(date +%s)"
echo -e "${GREEN}Restore started at: $(date) ${RESET}"
echo

# === Checks before MySQL is stopped: a mistake found later would leave an empty datadir ===
echo -e "${YELLOW}Checking the backups and the encryption key...${RESET}"
command -v aws > /dev/null || fail "AWS CLI is not installed or not in PATH. Please install the AWS CLI v2."

if [ -n "$SOURCE_SERVER" ]; then
    command -v xbcrypt > /dev/null || fail "xbcrypt (part of Percona XtraBackup) is not installed."
    command -v mysqlbinlog > /dev/null || fail "mysqlbinlog is not installed: it is needed to replay the binlogs."
    [ ! -e "$BINLOG_RESTORE_DIR" ] || fail "$BINLOG_RESTORE_DIR already exists: replay from it, or delete it first."
    [ -f "$DATA_DIR/xtrabackup_binlog_info" ] || fail "$DATA_DIR/xtrabackup_binlog_info does not exist: run this after an XtraBackup restore of a server with binlogs on."

    # The replay starts inside the binary log the restored data ended in:
    read -r START_BINLOG START_POSITION _ < "$DATA_DIR/xtrabackup_binlog_info"

    # Only the date folders from the backup's end on, and a day before it for a binlog uploaded just before a backup ended around midnight:
    # after an earlier restore, older date folders can hold the same binlog numbers from the old sequence:
    FIRST_DATE=$(date -d "$(sed -n 's/^end_time = \([0-9-]*\).*/\1/p' "$DATA_DIR/xtrabackup_info") -1 day" +%F) || fail "Unable to read the backup's end_time from $DATA_DIR/xtrabackup_info."
    BINLOG_OBJECTS=$(aws s3 ls --recursive "$BINLOG_S3_BUCKET/$SOURCE_SERVER/" | awk -F/ -v first_date="$FIRST_DATE" -v first_binlog="$START_BINLOG.xbcrypt" \
        '$(NF-1) >= first_date && $NF >= first_binlog {print $(NF-1) "/" $NF}' | sort -t/ -k2) || \
        fail "No binlogs of $SOURCE_SERVER found in $BINLOG_S3_BUCKET. Servers: aws s3 ls $BINLOG_S3_BUCKET/"
    [ -n "$BINLOG_OBJECTS" ] || fail "$START_BINLOG is not in $BINLOG_S3_BUCKET/$SOURCE_SERVER/: the replay must start from it."

    # They must be one unbroken sequence from START_BINLOG: a missing number is a gap the replay can't cross, a repeated one means two sequences:
    EXPECTED_NUMBER=$((10#${START_BINLOG##*.}))
    for OBJECT in $BINLOG_OBJECTS; do
        BINLOG="${OBJECT##*/}"
        BINLOG="${BINLOG%.xbcrypt}"
        [ $((10#${BINLOG##*.})) -eq "$EXPECTED_NUMBER" ] || fail "The binlogs in the bucket are not one unbroken sequence from $START_BINLOG: number $EXPECTED_NUMBER was expected, but the next one is $OBJECT. A gap, or the same numbers from two sequences (after an earlier restore)."
        EXPECTED_NUMBER=$((EXPECTED_NUMBER + 1))
    done
elif [ -n "$DUMP_FOLDER" ]; then
    [ ${#INCREMENTAL_BACKUPS[@]} -eq 0 ] || fail "A MySQL Shell archive has no incremental backups: give it alone."
    command -v xbcrypt > /dev/null || fail "xbcrypt (part of Percona XtraBackup) is not installed."
    [ ! -e "$DUMP_FOLDER" ] || fail "$DUMP_FOLDER already exists: load from it, or delete it first."
else
    [[ "$FULL_BACKUP" == *-dbfull.xbstream ]] || fail "The first backup must be a full backup (<time>-dbfull.xbstream) or a MySQL Shell archive (full-instance-backup-<time>.tar.xbcrypt): $FULL_BACKUP"
    command -v xtrabackup > /dev/null || fail "xtrabackup (part of Percona XtraBackup) is not installed."
    command -v xbstream > /dev/null || fail "xbstream (part of Percona XtraBackup) is not installed."
fi
PREVIOUS_BACKUP="$FULL_BACKUP"
for BACKUP in "${INCREMENTAL_BACKUPS[@]}"; do
    [[ "$BACKUP" == *-dbincr.xbstream ]] || fail "Not an incremental backup (<time>-dbincr.xbstream): $BACKUP"
    # The names start with the backup time, so the chain must be in increasing order:
    [[ "$BACKUP" > "$PREVIOUS_BACKUP" ]] || fail "The incremental backups must follow the full backup in time order: $BACKUP comes before $PREVIOUS_BACKUP"
    PREVIOUS_BACKUP="$BACKUP"
done

if [ -z "$SOURCE_SERVER" ]; then
    for BACKUP in "$FULL_BACKUP" "${INCREMENTAL_BACKUPS[@]}"; do
        aws s3 ls "$S3_BUCKET/$BACKUP" > /dev/null || fail "Not in the bucket: $S3_BUCKET/$BACKUP"
    done
fi

# The key goes into a file on the RAM disk, readable by root only (mktemp): xbstream reads it from there, so it never goes on
# a command line (ps shows those to every user) and is never printed. The trap removes it however the script ends:
KEY_FILE=$(mktemp -p /dev/shm mysql_restore_key.XXXXXX) || fail "Unable to create the encryption key file on the RAM disk /dev/shm."
trap 'rm -f "$KEY_FILE"' EXIT
ENCRYPTION_KEY=$(aws secretsmanager get-secret-value --secret-id "$ENCRYPTION_KEY_SECRET" --query SecretString --output text) || \
    fail "Unable to read the encryption key $ENCRYPTION_KEY_SECRET from AWS Secrets Manager."
[ ${#ENCRYPTION_KEY} -eq 32 ] || fail "The encryption key $ENCRYPTION_KEY_SECRET has ${#ENCRYPTION_KEY} characters instead of 32."
printf '%s' "$ENCRYPTION_KEY" > "$KEY_FILE"
unset ENCRYPTION_KEY
echo -e "${YELLOW}Backups found in the bucket, encryption key read from AWS Secrets Manager ($ENCRYPTION_KEY_SECRET).${RESET}"
echo

# === Binlogs: only fetched, then the script ends here, so MySQL and the datadir are not touched. A DBA replays them by hand ===
if [ -n "$SOURCE_SERVER" ]; then
    # Only root can read them: they are not encrypted:
    mkdir -p -m 700 "$BINLOG_RESTORE_DIR"

    # One at a time: streamed from the bucket, decrypted on the way. With pipefail, a failure of either fails the line. An incomplete set could be replayed by mistake, so it is deleted:
    for OBJECT in $BINLOG_OBJECTS; do
        BINLOG="${OBJECT##*/}"
        BINLOG="${BINLOG%.xbcrypt}"
        echo -e "${YELLOW}Fetching $OBJECT...${RESET}"
        aws s3 cp "$BINLOG_S3_BUCKET/$SOURCE_SERVER/$OBJECT" - | xbcrypt --decrypt --encrypt-algo=AES256 --encrypt-key-file="$KEY_FILE" > "$BINLOG_RESTORE_DIR/$BINLOG" || {
            rm -rf "$BINLOG_RESTORE_DIR"
            fail "The fetch of $BINLOG failed (see above) and $BINLOG_RESTORE_DIR was deleted. MySQL was not touched."; }
    done
    echo

    FETCH_DURATION=$(($(date +%s) - START_TIME))
    echo -e "${GREEN}Fetch Completed - ⏳ Total duration: $((FETCH_DURATION / 3600))h $(((FETCH_DURATION % 3600) / 60))m $((FETCH_DURATION % 60))s ${RESET}"
    echo

    # The GTID set is the third column. The server prints a line for each server_uuid in it, so the spaces and new lines go to compare them:
    GTIDS_IN_BACKUP=$(cut -f3- "$DATA_DIR/xtrabackup_binlog_info" | tr -d '\n ')
    GTIDS_ON_SERVER=$(mysql --login-path=local -N -B -r -e "SELECT @@GLOBAL.gtid_executed" | tr -d '\n ') || GTIDS_ON_SERVER="(unable to read it: check mysql --login-path=local)"

    echo -e "${CYAN}Nothing is replayed yet. First, the server must be where the backup ended, so these two must match:${RESET}"
    echo -e "  - GTIDs in the backup: $GTIDS_IN_BACKUP"
    echo -e "  - GTIDs on the server: $GTIDS_ON_SERVER"
    echo
    echo -e "${CYAN}Then find where to stop, reading the binlogs as text:${RESET}"
    echo -e "  mysqlbinlog --base64-output=decode-rows --verbose --start-position=$START_POSITION $BINLOG_RESTORE_DIR/${START_BINLOG%.*}.* | less"
    echo
    echo -e "${CYAN}Then replay, with one stop option or none. One command for all the binlogs (--start-position applies to the first one):${RESET}"
    echo -e "  mysqlbinlog --disable-log-bin --start-position=$START_POSITION <stop option> $BINLOG_RESTORE_DIR/${START_BINLOG%.*}.* | mysql --login-path=local --binary-mode"
    echo
    echo -e "${CYAN}The stop options:${RESET}"
    echo -e "  - Everything fetched:                    no stop option"
    echo -e "  - Stop at a time:                        --stop-datetime=\"2026-11-04 14:32:00\" (the local time of this machine: it stops at the first event at or after it)"
    echo -e "  - Stop just before a bad statement:      --stop-position=<position> (applies to the last file named: name the files one by one, up to that file)"
    echo -e "  - Skip one bad transaction, keep the rest: --exclude-gtids='<uuid>:<number>' (only if later transactions do not depend on it)"
    echo
    echo -e "${CYAN}Reminders for the replay:${RESET}"
    echo -e "  - Binlogs not in the bucket yet (kept from the old server)? Copy them into $BINLOG_RESTORE_DIR first: mysqlbinlog also reads one that was not closed."
    echo -e "  - --disable-log-bin keeps the replayed data out of this server's binlogs (each transaction leaves only an empty GTID entry), so replicas do not get it: rebuild them from a new backup."
    echo -e "  - MySQL stays CLOSED to clients until the replay is done and you run: systemctl restart mysqld"
    echo -e "  - The binlogs are not encrypted. When you finish: rm -rf $BINLOG_RESTORE_DIR"
    exit 0
fi

# === MySQL Shell archive: only fetched, then the script ends here, so MySQL, the datadir and the backup chains are not touched ===
if [ -n "$DUMP_FOLDER" ]; then
    # Only root can read the unpacked dump: it is not encrypted:
    mkdir -p -m 700 "$SHELL_RESTORE_DIR"
    echo -e "${YELLOW}Fetching $FULL_BACKUP into $SHELL_RESTORE_DIR...${RESET}"

    # One command: streamed from the bucket, decrypted and unpacked on the way. tar does not decompress the dump's files: util.loadDump reads them as they are (zstd).
    # With pipefail, a failure of any of the three fails the line. An incomplete folder could be loaded by mistake, so it is deleted:
    aws s3 cp "$S3_BUCKET/$FULL_BACKUP" - | xbcrypt --decrypt --encrypt-algo=AES256 --encrypt-key-file="$KEY_FILE" | tar -xvf - -C "$SHELL_RESTORE_DIR" || {
        rm -rf "$DUMP_FOLDER"
        fail "The fetch failed (see above) and the incomplete folder was deleted. MySQL was not touched."; }
    echo

    FETCH_DURATION=$(($(date +%s) - START_TIME))
    echo -e "${GREEN}Fetch Completed - ⏳ Total duration: $((FETCH_DURATION / 3600))h $(((FETCH_DURATION % 3600) / 60))m $((FETCH_DURATION % 60))s ${RESET}"
    echo
    echo -e "${CYAN}Nothing is restored yet. Choose what to load, in MySQL Shell (mysqlsh --login-path=local --js):${RESET}"
    echo -e "  - Check first, without changing anything: util.loadDump('$DUMP_FOLDER', {dryRun: true})"
    echo -e "  - The whole instance: util.loadDump('$DUMP_FOLDER')"
    echo -e "  - One database:       util.loadDump('$DUMP_FOLDER', {includeSchemas: ['db_name']})"
    echo -e "  - One table:          util.loadDump('$DUMP_FOLDER', {includeTables: ['db_name.table_name']})"
    echo
    echo -e "${CYAN}Reminders for the load:${RESET}"
    echo -e "  - The server needs local_infile=ON for the check and for the load: SET GLOBAL local_infile=ON, then OFF again afterwards."
    echo -e "  - Objects that already exist stop the load: drop them first, or load on another server."
    echo -e "  - Users are loaded only with {loadUsers: true}."
    echo -e "  - The load is written to the binary log, so replicas get it too. To keep it on this server only: {skipBinlog: true}."
    echo -e "  - The dump's binary log position, for a point-in-time recovery, is in $DUMP_FOLDER/@.json"
    echo -e "  - The folder is not encrypted. When you finish: rm -rf $DUMP_FOLDER"
    exit 0
fi

# From here on, a failure leaves MySQL stopped and the datadir incomplete: say so before the script ends (set -e):
trap 'echo -e "${RED}╰┈➤ Error: The restore failed (line $LINENO). mysqld is stopped and ${DATA_DIR} is incomplete: fix the error above and run the script again.${RESET}"' ERR

echo -e  "${YELLOW}Stopping mysqld...${RESET}"
systemctl stop mysqld
echo -e  "${YELLOW}Stopped mysqld.${RESET}"
echo
echo -e "${YELLOW}Cleaning ${DATA_DIR}...${RESET}"
rm -rf "${DATA_DIR:?}"/*
mkdir -p "$DATA_DIR"
chown -R mysql:mysql "$DATA_DIR"
echo -e "${YELLOW}Directory prepared at: $(date) ${RESET}"
# The old data is gone, so the old backup chains no longer match this server, even if the restore fails later:
rm -rf "$BACKUP_CHAIN_STATE" "$BINLOG_CHAIN_STATE"
echo -e "${YELLOW}Incremental backup chain and binlog chain stopped (${BACKUP_CHAIN_STATE} and ${BINLOG_CHAIN_STATE} deleted).${RESET}"
echo

# === Full backup: straight into the datadir ===
echo -e "${YELLOW}Starting restore from the full backup $FULL_BACKUP...${RESET}"
restore_backup "$FULL_BACKUP" "$DATA_DIR"
echo -e "${YELLOW}Restore finished at: $(date) ${RESET}"
echo

# With incremental backups to follow, --apply-log-only: redo only, no rollback of the open transactions yet,
# since a later incremental backup may hold their commit:
APPLY_LOG_ONLY=""
[ ${#INCREMENTAL_BACKUPS[@]} -gt 0 ] && APPLY_LOG_ONLY="--apply-log-only"
echo -e "${YELLOW}Preparing the full backup ${APPLY_LOG_ONLY}...${RESET}"
xtrabackup --prepare $APPLY_LOG_ONLY --use-memory="$PREPARE_MEMORY" --target-dir="$DATA_DIR"
echo -e "${YELLOW}Backup prepared at: $(date) ${RESET}"
show_binlog_position "Full backup reached"
echo

# === Incremental backups: one at a time, extracted into INCREMENTAL_DIR, applied to the datadir, then deleted ===
for i in "${!INCREMENTAL_BACKUPS[@]}"; do
    BACKUP="${INCREMENTAL_BACKUPS[$i]}"

    # Every incremental but the last is applied with --apply-log-only; the last one also rolls back the open transactions:
    APPLY_LOG_ONLY="--apply-log-only"
    [ $((i + 1)) -eq ${#INCREMENTAL_BACKUPS[@]} ] && APPLY_LOG_ONLY=""

    echo -e "${YELLOW}Starting restore from incremental backup $((i + 1)) of ${#INCREMENTAL_BACKUPS[@]}: $BACKUP...${RESET}"
    rm -rf "$INCREMENTAL_DIR"
    mkdir -p "$INCREMENTAL_DIR"
    restore_backup "$BACKUP" "$INCREMENTAL_DIR"
    echo -e "${YELLOW}Restore finished at: $(date) ${RESET}"
    echo
    echo -e "${YELLOW}Applying incremental backup $((i + 1)) to ${DATA_DIR} ${APPLY_LOG_ONLY}...${RESET}"
    xtrabackup --prepare $APPLY_LOG_ONLY --use-memory="$PREPARE_MEMORY" --target-dir="$DATA_DIR" --incremental-dir="$INCREMENTAL_DIR"
    rm -rf "$INCREMENTAL_DIR"
    echo -e "${YELLOW}Incremental backup applied and its folder deleted at: $(date) ${RESET}"
    show_binlog_position "Incremental backup $((i + 1)) of ${#INCREMENTAL_BACKUPS[@]} reached"
    echo
done

# Every backup is restored: the key is no longer needed (the trap removes it as well).
rm -f "$KEY_FILE"
echo -e "${YELLOW}Encryption key removed from the RAM disk.${RESET}"
echo

echo -e "${YELLOW}Creating relaylog, doublebuff, binlog, log directories...${RESET}"
cd "$DATA_DIR" && mkdir -p relaylog doublebuff binlog log
# xbstream wrote the files as root. restorecon gives them the SELinux label MySQL may use (mysqld_db_t) where SELinux is installed:
chown -R mysql:mysql "$DATA_DIR"
command -v restorecon > /dev/null && restorecon -R "$DATA_DIR"
echo
echo -e "${YELLOW}Starting mysqld, CLOSED to clients...${RESET}"
# MySQL comes up closed, so nothing can write before a binlog replay or the DBA's checks: only the local socket works, with no replication and no scheduled events.
# MYSQLD_OPTS is set only for this start: unset right after it, so a plain systemctl restart mysqld opens MySQL (a reboot does too):
systemctl set-environment MYSQLD_OPTS="--skip-networking --skip-replica-start --event-scheduler=OFF"
systemctl start mysqld || { systemctl unset-environment MYSQLD_OPTS; fail "mysqld did not start (see systemctl status mysqld). ${DATA_DIR} is restored: fix the error, then run systemctl start mysqld."; }
systemctl unset-environment MYSQLD_OPTS
# /etc/sysconfig/mysql overrides MYSQLD_OPTS, so check that mysqld really got it. An open server could take writes before the DBA is ready, so it is stopped:
grep -qa -- --skip-networking "/proc/$(systemctl show --property=MainPID --value mysqld)/cmdline" || {
    systemctl stop mysqld
    fail "mysqld started without --skip-networking, so it would be open to clients, and it was stopped. Check /etc/sysconfig/mysql and systemctl cat mysqld. ${DATA_DIR} is restored."; }
echo -e "${YELLOW}Started mysqld, CLOSED to clients.${RESET}"
trap - ERR
echo
END_TIME=$(date +%s)
RESTORE_DURATION=$((END_TIME - START_TIME))
# Convert seconds to hours/minutes/seconds
HOURS=$((RESTORE_DURATION / 3600))
MINUTES=$(((RESTORE_DURATION % 3600) / 60))
SECONDS=$((RESTORE_DURATION % 60))
echo -e "${GREEN}Restore Completed - ⏳ Total restore duration: ${HOURS}h ${MINUTES}m ${SECONDS}s ${RESET}"
echo

# === MySQL is closed, and where the restored data ends ===
echo -e "${YELLOW}MySQL is CLOSED to clients: only the local socket works, with no replication and no scheduled events.${RESET}"
echo -e "${YELLOW}It stays closed until you finish your checks and any binlog replay, and run: systemctl restart mysqld${RESET}"
echo
show_binlog_position "Next binlog to replay (the restored data ends here)"
echo -e "${CYAN}To fetch it and the binlogs after it: $0 --fetch_binlogs <server the backup came from> (servers: aws s3 ls $BINLOG_S3_BUCKET/)${RESET}"
echo

# === What changed with the restore ===
echo -e "${CYAN}Reminders after the restore:${RESET}"
echo -e "  - New server_uuid: auto.cnf is not in the backup, so MySQL generated a new one: $(sed -n 's/^server-uuid=//p' "$DATA_DIR/auto.cnf" 2>/dev/null)"
echo -e "  - New TLS certificates: the *.pem files are not in the backup and were generated again. Clients that verify the server need the new CA."
echo -e "  - A new binary log sequence starts, whatever its numbers (SHOW BINARY LOGS): they can repeat names already in the bucket."
echo -e "  - The binlog chain was stopped: --continuous_binlog_backup fails until a new full backup, then --init_binlog_chain (see its --help)."
echo -e "  - The incremental backup chain was stopped: --xtrabackup_incremental fails until a full backup (--xtrabackup) starts a new chain."
