#!/bin/bash
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
# WARNING: it stops MySQL and deletes everything in the datadir.

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
# Memory for the prepare (xtrabackup's default is only 100M). MySQL is stopped, so most of the free RAM (production: 64GB, as in mysql_restore.sh):
PREPARE_MEMORY="2G"
# Set to the key file on the RAM disk once the key is read:
KEY_FILE=""

# === Backup arguments: the full backup, then its incremental backups in order (names as aws s3 ls shows them) ===
FULL_BACKUP="${1:-}"
INCREMENTAL_BACKUPS=("${@:2}")

if [ -z "$FULL_BACKUP" ]; then
    echo
    echo -e "${RED}╰┈➤ Error: Missing Xtrabackup backup argument.${RESET}"
    echo "======================================================================================================================"
    echo
    echo -e " ${CYAN}--Example Usage:${RESET}         | $0 2026-10-31-130108-dbfull.xbstream"
    echo
    echo -e " ${CYAN}--With Incrementals:${RESET}     | $0 2026-10-31-130108-dbfull.xbstream \\"
    echo -e "                          |     2026-10-31-131934-dbincr.xbstream 2026-10-31-132156-dbincr.xbstream"
    echo -e "                          | The full backup first, then its incremental backups in order, up to the one to restore."
    echo
    echo -e " ${CYAN}--Check Latest Backups:${RESET}  | aws s3 ls $S3_BUCKET/ --human-readable | grep xbstream"
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


echo
echo "======================================================================================================================"
echo
echo -e "${GREEN} Starting MySQL restore using Xtrabackup:${RESET} $FULL_BACKUP + ${#INCREMENTAL_BACKUPS[@]} incremental backup(s)"
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

[[ "$FULL_BACKUP" == *-dbfull.xbstream ]] || fail "The first backup must be a full backup (<time>-dbfull.xbstream): $FULL_BACKUP"
PREVIOUS_BACKUP="$FULL_BACKUP"
for BACKUP in "${INCREMENTAL_BACKUPS[@]}"; do
    [[ "$BACKUP" == *-dbincr.xbstream ]] || fail "Not an incremental backup (<time>-dbincr.xbstream): $BACKUP"
    # The names start with the backup time, so the chain must be in increasing order:
    [[ "$BACKUP" > "$PREVIOUS_BACKUP" ]] || fail "The incremental backups must follow the full backup in time order: $BACKUP comes before $PREVIOUS_BACKUP"
    PREVIOUS_BACKUP="$BACKUP"
done

for BACKUP in "$FULL_BACKUP" "${INCREMENTAL_BACKUPS[@]}"; do
    aws s3 ls "$S3_BUCKET/$BACKUP" > /dev/null || fail "Not in the bucket: $S3_BUCKET/$BACKUP"
done

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
echo -e "${YELLOW}Starting mysqld...${RESET}"
systemctl start mysqld
echo -e "${YELLOW}Started mysqld.${RESET}"
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

# === What changed with the restore ===
echo -e "${CYAN}Reminders after the restore:${RESET}"
echo -e "  - New server_uuid: auto.cnf is not in the backup, so MySQL generated a new one: $(sed -n 's/^server-uuid=//p' "$DATA_DIR/auto.cnf" 2>/dev/null)"
echo -e "  - New TLS certificates: the *.pem files are not in the backup and were generated again. Clients that verify the server need the new CA."
echo -e "  - Binary log numbering starts again: the binlog backup chain needs a new full backup, then --init_binlog_chain (see its --help)."
echo -e "  - The incremental backup chain of this server belongs to the old data: take a full backup (--xtrabackup) before the next --xtrabackup_incremental."
echo -e "  - The restored data ends at this binary log position (a point-in-time recovery continues from here): $(tr '\t' ' ' < "$DATA_DIR/xtrabackup_binlog_info" 2>/dev/null)"
