#!/bin/bash

# =================================================================================================================================
# BEFORE THE FIRST RUN ON A SERVER: what to set up and what to decide (details in the numbered notes and at the variables below).
#
# Set up:
#  - pgBackRest, configured and working: /etc/pgbackrest.conf with this cluster's stanza (PGBACKREST_STANZA), WAL archiving on,
#    and `pgbackrest --stanza=<stanza> check` passing as postgres.
#  - The repository encrypted: repo1-cipher-type=aes-256-cbc and repo1-cipher-pass in /etc/pgbackrest.conf (owner root, group
#    postgres, mode 640). --pg_dump encrypts its archives with the same passphrase: one per cluster. Keep the passphrase in the secret
#    store, and a copy outside it, for as long as any backup encrypted with it: without it nothing can be restored. pgBackRest cannot
#    change the passphrase of an existing repository.
#  - S3_BUCKET: the bucket and folder of this server's logical backups (pg_dump). Never a lifecycle rule on pgBackRest's own folder:
#    pgBackRest deletes its old backups and WAL itself, and a rule that deletes files by age breaks its repository.
#  - The server's IAM role: s3:PutObject on the pg_dump folder (pgBackRest's access to its own folder comes with its setup).
#  - Installed: pgBackRest, jq, gpg (GnuPG 2), the AWS CLI v2 for --pg_dump, and PostgreSQL's client tools of the server's major
#    version in PG_BIN_DIR (psql, pg_dump, pg_dumpall).
#  - BACKUP_DIR (/backup): its own disk, with room for the newest pg_dump folder and three days of pg_dump archives.
#  - BACKUP_LOCK_DATABASE: the database where the application's jobs take the backup_running lock (see 2).
#  - node_exporter reads TEXTFILE_COLLECTOR_DIR (--collector.textfile.directory), for the backup metrics.
#  - The log rotation: cp postgresql_backup.logrotate.example /etc/logrotate.d/postgresql_backup
#  - The cron entries in /etc/cron.d/postgresql_backup (example in 7).
#
# Decide:
#  - The schedule: how often a full backup, with incremental backups on the other days (example in 7: fulls on Monday and Friday),
#    and when --pg_dump runs: not at the same time as pgBackRest, since both read the whole database.
#  - The retention: repo1-retention-full in /etc/pgbackrest.conf for the physical backups (pgBackRest expires them itself), and an
#    S3 lifecycle rule on the pg_dump folder for the logical ones.
#  - The alerts: node_postgresql_backup_* (with two fulls a week, the full backup's age reaches 4 days),
#    node_postgresql_incremental_backup_* and node_postgresql_logical_backup_* (pg_dump, on its own schedule).
#  - UPLOAD_TIMEOUT: well above the slowest normal upload of a logical backup.
#  - The load on the server: PG_DUMP_JOBS for pg_dump, and process-max in /etc/pgbackrest.conf for pgBackRest.
#  - The pg_dump folder: only its archive is encrypted. The folder itself stays unencrypted in BACKUP_DIR for a day or two
#    (manage_old_backups), for a fast local restore. Its globals.sql holds the roles' password hashes.
# =================================================================================================================================

set -uo pipefail

# No core dumps: a crashing gpg would write its memory, and the passphrase in it, to disk (systemd-coredump):
ulimit -c 0

# Main script for exporting LOGICAL and PHYSICAL production PostgreSQL backups. (Version 1, AWS)
# 1) Uses pgBackRest for physical backups (full and incremental, straight into its repository in the bucket) and pg_dump for logical
#    backups (every database, plus the roles and tablespaces).
# 2) Holds the PostgreSQL advisory lock 'backup_running' during the backup: the application's jobs check it and do not run while it is held.
#    An advisory lock belongs to one database, so the jobs take it in BACKUP_LOCK_DATABASE, the same way as the script:
#    SELECT pg_try_advisory_lock(hashtextextended('backup_running', 0));   (false while a backup runs; the number is -7932505551318357049)
#    From any other database, pg_locks shows it: locktype 'advisory', classid 2448036922, objid 3000691655, objsubid 1.
# 3) Releases the lock upon backup completion / failure / interruption. A file lock (flock) keeps a second run of this script from starting.
# 4) pgBackRest uploads its backups itself and expires the old ones. The logical backups are transferred to the S3 bucket, with a time
#    limit (UPLOAD_TIMEOUT). pgBackRest and the AWS CLI take their credentials from the server's IAM role.
# 5) Updates node_exporter text collector files for Grafana backup monitoring in case of SUCCESS or FAILURE.
# 6) Logical backups can be performed LOCALLY (--pg_dump_local). Physical backups always go to pgBackRest's repository.
# 7) Logs every backup run (normal execution and errors, with colors) to /var/log/postgresql_backup.log. Before the script runs from cron,
#    install its rotation: cp postgresql_backup.logrotate.example /etc/logrotate.d/postgresql_backup (the log grows without it).
#    pgBackRest also writes its own detailed logs to /var/log/pgbackrest/.
#    The script logs itself, so cron's copy of the output goes to /dev/null, e.g. in /etc/cron.d/postgresql_backup (full backups on
#    Monday and Friday, incremental backups on the other days):
#    0 2 * * 1,5 root /opt/scripts/postgresql_backup_v1_aws.sh --pgbackrest > /dev/null 2>&1
#    0 2 * * 0,2,3,4,6 root /opt/scripts/postgresql_backup_v1_aws.sh --pgbackrest_incremental > /dev/null 2>&1
# 8) Encryption: pgBackRest encrypts its repository itself (repo1-cipher-type, repo1-cipher-pass). The pg_dump archives are encrypted
#    with gpg (AES256) with the same passphrase, read from /etc/pgbackrest.conf into a file on the RAM disk (/dev/shm) for the backup
#    only, and never printed. gpg checks the archive when it decrypts: a damaged or altered archive fails instead of decrypting into
#    wrong data. To restore a logical backup: put the passphrase in a file (mode 600), then
#    gpg --batch --pinentry-mode loopback --passphrase-file <file> --decrypt <archive>.tar.gpg | tar -xf -
#    then psql -f globals.sql for the roles, and pg_restore for each database folder: pg_restore -j <N> -d <database> <folder>.
# 9) Incremental pgBackRest backups in a chain (--pgbackrest_incremental): each one holds only what changed since the backup before it
#    (the full backup, or the incremental before it). pgBackRest keeps track of the chain in its repository. A full backup (--pgbackrest)
#    starts a new chain. Without a full backup an incremental fails, because pgBackRest would quietly take a full one instead.
#    To restore: pgbackrest --stanza=<stanza> restore picks the backups of the chain and the WAL it needs (with --type=time --target=...
#    for a moment between backups). For differential backups instead (each one since the last full): --type=diff in
#    pgbackrest_incremental_backup.
# 10) Only the primary takes backups: on a replica (pg_is_in_recovery()) a run logs that and ends with exit 0, without metrics. The same
#     cron entries can then sit on every server of a cluster.


# Colors for output:
WHITE="\e[1m"
GREEN="\e[32m"
CYAN="\e[36m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

# Variables:
CURRENT_TIME=`date +%Y-%m-%d-%H%M%S`
BACKUP_DIR="/backup"
# This run's pg_dump folder: a pg_dump folder for each database, and globals.sql (roles and tablespaces):
BACKUP_DIR_DUMP="${BACKUP_DIR}/pg-dump-${CURRENT_TIME}"
# The encrypted archive of the pg_dump folder: kept in BACKUP_DIR, uploaded to the bucket:
DUMP_ARCHIVE="pg-dump-${CURRENT_TIME}.tar.gpg"
# PostgreSQL's client tools, of the server's major version:
PG_BIN_DIR="/usr/pgsql-17/bin"
# Parallel pg_dump workers per database (each one is a connection to the database):
PG_DUMP_JOBS=4
# The pgBackRest stanza of this cluster. Set it before the first run (the value below is the aws-dba-labs lab's):
PGBACKREST_STANZA="postgresql-single"
# pgBackRest's configuration: --pg_dump reads the passphrase (repo1-cipher-pass) from it:
PGBACKREST_CONFIG="/etc/pgbackrest.conf"
# The database where the advisory lock 'backup_running' is held: the one where the application's jobs take it (see 2).
# Set it before the first run (the value below is the aws-dba-labs lab's application database):
BACKUP_LOCK_DATABASE="shop"
# Empty if the AWS CLI is not installed: main reports it once the log has started.
AWS_BINARY_PATH=$(which aws 2>/dev/null)
# Set the S3 bucket and folder of this server's logical backups before the first run (in the aws-dba-labs lab: terraform output backup_bucket, folder pg_dump):
S3_BUCKET="s3://BUCKET/pg_dump"
# Set by fetch_encryption_key for the duration of the logical backup: the passphrase file and gpg's home folder, both on the RAM disk:
ENCRYPTION_KEY_FILE=""
GNUPG_HOME=""
TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector/"
# The name in the metrics and their files: backup for full backups, incremental_backup for --pgbackrest_incremental and logical_backup
# for --pg_dump (set in main), so each has its own status, durations, size and age, e.g. node_postgresql_incremental_backup_status in
# postgresql_incremental_backup_status.prom:
METRICS_NAME="backup"
# The size of this run's backup in bytes, for the metrics: what pgBackRest added to its repository, or the size of the pg_dump archive:
BACKUP_SIZE=""
LOCK_FILE="/var/lock/postgresql_backup.lock"
LOG_FILE="/var/log/postgresql_backup.log"
# An upload that takes longer is stopped and the transfer fails. Keep it well above the slowest normal upload (node_postgresql_logical_backup_transfer_duration_seconds):
UPLOAD_TIMEOUT="12h"
BACKUP_TIMESTAMP=$(($(date +%s) * 1000))
# The server's name in the log and in the metrics (instance label):
SERVER_NAME=$(hostname -s)


# Function Help:
show_help() {
    echo "================================================================================================================================="
    echo
    echo -e "${GREEN}Available Backup Options:${RESET} 🔧"
    echo
    echo -e "  ${CYAN}--pgbackrest${RESET}              | Full physical backup with pgBackRest (encrypted), straight into its repository in the S3 bucket."
    echo -e "                              | It starts a new chain for --pgbackrest_incremental."
    echo -e "  ${CYAN}--pgbackrest_incremental${RESET}  | Incremental backup with pgBackRest (encrypted): only what changed since the last backup of the chain."
    echo -e "                              | It fails until a full backup (--pgbackrest) starts a chain."
    echo -e "  ${CYAN}--pg_dump${RESET}                 | Logical backup of every database and the roles with pg_dump (encrypted archive), transferred to the S3 bucket."
    echo -e "  ${CYAN}--pg_dump_local${RESET}           | Perform a local logical backup with pg_dump (encrypted archive)."
    echo -e "  ${CYAN}--help${RESET}                    | Display this help message."
    echo
    echo -e "  Every backup run is logged to $LOG_FILE (with colors: less -R $LOG_FILE)."
    echo
    echo "================================================================================================================================="
}


# Function to copy everything this run prints (normal execution and errors, with their colors) to the log file as well as to the screen.
# Each run starts with a header line. Read the log with its colors: less -R on the log file.
start_log(){
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo
    echo -e "${CYAN}===== $(date '+%Y-%m-%d %H:%M:%S') | $SERVER_NAME | $1 =====${RESET}"
}




# Function to check that this server is the primary: a replica (in recovery) takes no backups (see 10).
# If PostgreSQL does not answer, the run goes on, and the backup fails with its own error and the failure metrics:
check_primary(){
    local IN_RECOVERY
    IN_RECOVERY=$(cd / && runuser -u postgres -- "${PG_BIN_DIR}/psql" -X -A -t -c "SELECT pg_is_in_recovery()" 2>/dev/null)
    if [ "$IN_RECOVERY" == "t" ]; then
        echo -e "${YELLOW}-- This server is a replica (in recovery): only the primary takes backups. Nothing to do. --${RESET}"
        return 1
    fi
    return 0
}



# Function to take the PostgreSQL advisory lock 'backup_running' for the duration of the backup (the application's jobs check it, see 2):
acquire_backup_lock(){
    BACKUP_LOCK_NAME="backup_running"

    echo -e "${YELLOW}-- Attempting to acquire database lock named: ${BACKUP_LOCK_NAME} (database ${BACKUP_LOCK_DATABASE}) --${RESET}"

    # The lock session writes its answers to this file (psql writes each answer at once), so the script can read whether the lock was taken:
    local LOCK_ANSWER_FILE
    LOCK_ANSWER_FILE=$(mktemp -t postgresql_backup_lock.XXXXXX) || {
        echo -e "${RED}-- Error: Unable to create a temporary file for the lock session. --${RESET}"
        return 1; }

    # Start a background process to hold the lock: a psql session (as postgres) that ends, and releases the lock, when its input (fd 3) is
    # closed. pgbackrest / pg_dump inherit fd 3, so if this script is killed the lock stays held until the backup tool has finished too.
    # The session shows in pg_stat_activity as application postgresql_backup_lock:
    exec 3> >(cd / && runuser -u postgres -- "${PG_BIN_DIR}/psql" -X -q -A -t \
        -d "dbname=${BACKUP_LOCK_DATABASE} application_name=postgresql_backup_lock" > "$LOCK_ANSWER_FILE")
    local LOCK_SESSION_PID="${!:-}"

    # No idle timeout for THIS SESSION ONLY, so the idle session is not disconnected during a long backup.
    # pg_try_advisory_lock takes the lock or returns false at once: checking and taking it is one step, so two sessions can never both get it.
    # SIGPIPE is ignored for this one write, so a session that already died (PostgreSQL down, no such database) cannot kill the script:
    trap '' PIPE
    echo "SET idle_session_timeout = 0; SELECT pg_try_advisory_lock(hashtextextended('${BACKUP_LOCK_NAME}', 0));" >&3 2>/dev/null
    trap - PIPE

    # Wait up to 60 s for the answer, and stop early if the session has already ended (psql prints its error above):
    local LOCK_RESULT="" WAITED=0
    while [ "$WAITED" -lt 600 ]; do
        read -r LOCK_RESULT < "$LOCK_ANSWER_FILE"
        [ -n "$LOCK_RESULT" ] && break
        [ -n "$LOCK_SESSION_PID" ] && ! kill -0 "$LOCK_SESSION_PID" 2>/dev/null && break
        sleep 0.1
        WAITED=$((WAITED + 1))
    done
    rm -f "$LOCK_ANSWER_FILE"

    if [ "$LOCK_RESULT" != "t" ]; then
        if [ "$LOCK_RESULT" == "f" ]; then
            echo -e "${RED}-- Error: Could not acquire lock: ${BACKUP_LOCK_NAME} is held by another session (another backup, or an application job). --${RESET}"
        else
            echo -e "${RED}-- Error: Could not acquire lock: no answer from PostgreSQL to pg_try_advisory_lock (got: '${LOCK_RESULT}'). See the psql error above, if any. --${RESET}"
        fi
        release_backup_lock
        return 1
    fi

    # Setup Trap for safety | If the script exits / is interrupted / or is killed, close the session to release the lock,
    # and remove the passphrase from the RAM disk:
    trap 'remove_encryption_key; release_backup_lock; echo -e "${RED}-- Lock released by trap. --${RESET}"' EXIT INT TERM

    echo -e "${GREEN}-- Lock acquired successfully. --${RESET}"
}


# Function to release the advisory lock: closing fd 3 ends the lock session, and PostgreSQL releases the lock with it (safe to call twice):
release_backup_lock(){
    exec 3>&-
}



# Function to read the passphrase from pgBackRest's configuration (repo1-cipher-pass) into a file on the RAM disk (/dev/shm), for this
# backup only, and to give gpg a home folder there. gpg reads the passphrase from the file (--passphrase-file): on the RAM disk it never
# reaches a disk, and mktemp makes the file readable by root only. The passphrase never goes on a command line (ps shows those to every
# user) and is never printed, so it stays out of the log:
fetch_encryption_key(){
    if [ ! -r "$PGBACKREST_CONFIG" ]; then
        echo -e "${RED}Error: Unable to read $PGBACKREST_CONFIG: the passphrase for the archive cannot be read.${RESET}"
        return 1
    fi

    local PASSPHRASE
    PASSPHRASE=$(sed -n 's/^[[:space:]]*repo1-cipher-pass[[:space:]]*=[[:space:]]*//p' "$PGBACKREST_CONFIG" | head -n 1)
    if [ -z "$PASSPHRASE" ]; then
        echo -e "${RED}Error: No repo1-cipher-pass in $PGBACKREST_CONFIG: the repository is not encrypted, so there is no passphrase for the archive.${RESET}"
        return 1
    fi

    ENCRYPTION_KEY_FILE=$(mktemp -p /dev/shm postgresql_backup_key.XXXXXX) || {
        echo -e "${RED}Error: Unable to create the passphrase file on the RAM disk /dev/shm.${RESET}"
        return 1; }

    # printf is built into bash: the passphrase is written to the file without ever being on a command line:
    printf '%s' "$PASSPHRASE" > "$ENCRYPTION_KEY_FILE"

    # gpg's own folder for this run (gpg starts an agent there, which remove_encryption_key stops):
    GNUPG_HOME=$(mktemp -d -p /dev/shm postgresql_backup_gnupg.XXXXXX) || {
        echo -e "${RED}Error: Unable to create gpg's folder on the RAM disk /dev/shm.${RESET}"
        return 1; }
    echo -e "${GREEN}-- Passphrase read from $PGBACKREST_CONFIG (repo1-cipher-pass). --${RESET}"
}


# Function to remove the passphrase file from the RAM disk and stop gpg's agent (safe to call twice, and when there is no key file):
remove_encryption_key(){
    [ -n "$ENCRYPTION_KEY_FILE" ] && rm -f "$ENCRYPTION_KEY_FILE"
    ENCRYPTION_KEY_FILE=""
    if [ -n "$GNUPG_HOME" ]; then
        gpgconf --homedir "$GNUPG_HOME" --kill gpg-agent 2>/dev/null
        rm -rf "$GNUPG_HOME"
    fi
    GNUPG_HOME=""
}



# Function to count the full backups of the cluster in pgBackRest's repository (of its current PostgreSQL version, after an upgrade):
count_full_backups(){
    cd / && runuser -u postgres -- pgbackrest --stanza="${PGBACKREST_STANZA}" --output=json info | \
        jq '.[0] as $s | ($s.db | map(.id) | max) as $db | [$s.backup[]? | select(.type == "full" and .database.id == $db)] | length'
}


# Function to read the size of the backup this run made: what pgBackRest added to its repository for it (its newest backup).
# $1 is the type this run asked for (full or incr): a different type in the repository is reported:
read_backup_size(){
    local LABEL TYPE
    read -r LABEL TYPE BACKUP_SIZE <<< "$(cd / && runuser -u postgres -- pgbackrest --stanza="${PGBACKREST_STANZA}" --output=json info | \
        jq -r '.[0].backup[-1] | "\(.label) \(.type) \(.info.repository.delta)"')"
    echo -e "${YELLOW}In the repository:${RESET} backup ${LABEL:-?} (${TYPE:-?}), ${BACKUP_SIZE:-?} bytes added"
    if [ "${TYPE:-}" != "$1" ]; then
        echo -e "${YELLOW}Warning: pgBackRest's newest backup is of type '${TYPE:-?}', not '$1' as this run asked: see /var/log/pgbackrest/.${RESET}"
    fi
}



# Function for a full pgBackRest Backup:
pgbackrest_backup(){
    if command -v pgbackrest >/dev/null 2>&1; then
        acquire_backup_lock || return 1
        echo -e "${YELLOW}Starting pgBackRest Full Backup at ${CURRENT_TIME} ${RESET}"

        # Start time of the backup script:
        START_BACKUP="$(date +%s)"

        # Run pgBackRest as postgres (runuser keeps the current folder: / is one postgres may enter). It copies the data files, compressed
        # and encrypted, into its repository, then expires the backups and WAL that the retention no longer needs:
        cd / && runuser -u postgres -- pgbackrest --stanza="${PGBACKREST_STANZA}" --type=full backup

        # Save Backup Exit Code:
        PGBACKREST_EXIT_CODE=$?

        # Release the lock (closing the input of the lock session ends it) and clear the trap:
        release_backup_lock && \
        trap - EXIT INT TERM && \
        echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"

        if [ $PGBACKREST_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}pgBackRest Full Backup failed.${RESET}"
            return 1
        fi

        # End time of the backup script.
        END_BACKUP="$(date +%s)"

        # Calculate backup duration:
        DURATION_BACKUP="$(( ($END_BACKUP - $START_BACKUP) + 2 ))"
        read_backup_size full
        echo
        echo -e "${YELLOW}Duration in Seconds:${RESET} $(($END_BACKUP - $START_BACKUP))"
        return 0

    else
        echo -e "${RED}pgBackRest is not installed.${RESET}"
        return 1
    fi
}



# Function for an incremental pgBackRest Backup in a chain: only what changed since the last backup in the repository (see 9):
pgbackrest_incremental_backup(){
    if command -v pgbackrest >/dev/null 2>&1; then
        command -v jq >/dev/null 2>&1 || {
            echo -e "${RED}jq is not installed: the backups in pgBackRest's repository cannot be read.${RESET}"
            return 1; }

        # Without a full backup there is no chain to continue, and pgBackRest would take a full backup instead: a person takes a full
        # backup (--pgbackrest), which starts a new chain:
        local FULL_BACKUPS
        FULL_BACKUPS=$(count_full_backups)
        if ! [[ "$FULL_BACKUPS" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Error: Unable to read pgBackRest's repository (pgbackrest info, stanza ${PGBACKREST_STANZA}).${RESET}"
            return 1
        fi
        if [ "$FULL_BACKUPS" -eq 0 ]; then
            echo -e "${RED}Error: No full backup in the repository to build the incremental backup on. Take a full backup first (--pgbackrest).${RESET}"
            return 1
        fi

        acquire_backup_lock || return 1
        echo -e "${YELLOW}Starting pgBackRest Incremental Backup at ${CURRENT_TIME} ${RESET}"

        # Start time of the backup script:
        START_BACKUP="$(date +%s)"

        # Run pgBackRest as for the full backup, with --type=incr: it copies only what changed since the last backup of the chain:
        cd / && runuser -u postgres -- pgbackrest --stanza="${PGBACKREST_STANZA}" --type=incr backup

        # Save Backup Exit Code:
        PGBACKREST_EXIT_CODE=$?

        # Release the lock (closing the input of the lock session ends it) and clear the trap:
        release_backup_lock && \
        trap - EXIT INT TERM && \
        echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"

        if [ $PGBACKREST_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}pgBackRest Incremental Backup failed.${RESET}"
            return 1
        fi

        # End time of the backup script.
        END_BACKUP="$(date +%s)"

        # Calculate backup duration:
        DURATION_BACKUP="$(( ($END_BACKUP - $START_BACKUP) + 2 ))"
        read_backup_size incr
        echo
        echo -e "${YELLOW}Duration in Seconds:${RESET} $(($END_BACKUP - $START_BACKUP))"
        return 0

    else
        echo -e "${RED}pgBackRest is not installed.${RESET}"
        return 1
    fi
}



# Function for a pg_dump Backup (logical): every database, and the roles and tablespaces:
pg_dump_backup(){

    if [ -x "${PG_BIN_DIR}/pg_dump" ] && [ -x "${PG_BIN_DIR}/pg_dumpall" ]; then
        # Checked before the dump: without gpg the run would fail only at the archive, after the whole dump:
        command -v gpg >/dev/null 2>&1 || {
            echo -e "${RED}gpg is not installed: the archive cannot be encrypted.${RESET}"
            return 1; }

        acquire_backup_lock || return 1
        echo -e "${YELLOW}Starting pg_dump Backup at ${CURRENT_TIME} ${RESET}"

        # Start time of the backup script:
        START_BACKUP="$(date +%s)"

        # Read the passphrase for the archive, also before the dump (the lock's trap removes it if the script is stopped):
        fetch_encryption_key || {
            remove_encryption_key
            release_backup_lock && \
            trap - EXIT INT TERM && \
            echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"
            return 1; }

        # pg_dump runs as postgres, so the folder of this run belongs to postgres (runuser keeps the current folder: BACKUP_DIR).
        # Any failure below fails the whole backup, but the other databases are still dumped:
        local DUMP_EXIT_CODE=0
        cd ${BACKUP_DIR} || { echo -e "${RED}Error: Failed to change directory to ${BACKUP_DIR} ${RESET}"; DUMP_EXIT_CODE=1; }
        mkdir -p "${BACKUP_DIR_DUMP}" && chown postgres:postgres "${BACKUP_DIR_DUMP}" || DUMP_EXIT_CODE=1

        if [ "$DUMP_EXIT_CODE" -eq 0 ]; then
            # The roles (with their password hashes) and tablespaces: pg_dump leaves them out, since they belong to the whole cluster:
            runuser -u postgres -- "${PG_BIN_DIR}/pg_dumpall" --globals-only --file="${BACKUP_DIR_DUMP}/globals.sql" || DUMP_EXIT_CODE=1

            # Every database that takes connections, except the templates. Each one into its own folder, in pg_dump's directory format:
            # PG_DUMP_JOBS tables at a time, each file compressed with zstd. Each dump is consistent within its database:
            local DATABASES DATABASE
            DATABASES=$(runuser -u postgres -- "${PG_BIN_DIR}/psql" -X -A -t \
                -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname") || DUMP_EXIT_CODE=1
            while IFS= read -r DATABASE; do
                [ -n "$DATABASE" ] || continue
                echo -e "${YELLOW}-- pg_dump of database ${DATABASE} --${RESET}"
                runuser -u postgres -- "${PG_BIN_DIR}/pg_dump" --format=directory --jobs="${PG_DUMP_JOBS}" --compress=zstd \
                    --file="${BACKUP_DIR_DUMP}/${DATABASE}" --dbname="${DATABASE}" || DUMP_EXIT_CODE=1
            done <<< "$DATABASES"
        fi

        # Release the lock (closing the input of the lock session ends it): the archive does not need it.
        # The trap stays until the passphrase is removed:
        release_backup_lock && \
        echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released. --${RESET}"

        if [ "$DUMP_EXIT_CODE" -ne 0 ]; then
            remove_encryption_key
            trap - EXIT INT TERM
            echo -e "${RED}pg_dump Backup Failed!${RESET}"
            return 1
        fi

        # Archive the pg_dump folder without compressing it again: the dump files are already compressed (zstd).
        # gpg encrypts it (AES256) as it is written, so an unencrypted archive never reaches the disk. With pipefail, a failure of tar or gpg
        # fails this step. The relative name stores the folder as pg-dump-<time>/ instead of under its full path:
        cd ${BACKUP_DIR} && time tar -cf - "pg-dump-${CURRENT_TIME}" | \
            gpg --homedir "${GNUPG_HOME}" --batch --yes --pinentry-mode loopback --passphrase-file "${ENCRYPTION_KEY_FILE}" \
                --no-symkey-cache --symmetric --cipher-algo AES256 --compress-algo none --output "${DUMP_ARCHIVE}"

        # Save the archive's exit code:
        FOLDER_ARCHIVE_STATUS=$?

        # The archive no longer needs the passphrase: remove it from the RAM disk, stop gpg's agent and clear the trap.
        remove_encryption_key
        trap - EXIT INT TERM

        if [ $FOLDER_ARCHIVE_STATUS -ne 0 ]; then
            echo -e "${RED}Backup Folder Archive Failed!${RESET}"
            return 1
        fi

        BACKUP_SIZE=$(stat -c %s "${BACKUP_DIR}/${DUMP_ARCHIVE}" 2>/dev/null)

        # End time of the backup script:
        END_BACKUP="$(date +%s)"

        # Calculate backup duration:
        DURATION_BACKUP="$(( ($END_BACKUP - $START_BACKUP) + 2 ))"
        echo
        echo -e "${YELLOW}Duration in Seconds:${RESET} $(($END_BACKUP - $START_BACKUP))"
        return 0  # Success

    else
        echo -e "${RED}pg_dump / pg_dumpall not found in ${PG_BIN_DIR}.${RESET}"
        return 1  # Failure
    fi
}



# Function to Delete old local backups (pg_dump folders after a day or two, pg_dump archives after 3 days):
manage_old_backups() {
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type d -name 'pg-dump-*' -mtime +0 -exec rm -rfv {} \;
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type f -name 'pg-dump-*.tar.gpg' -mtime +2 -exec rm -fv {} \;
    echo -e "${GREEN}Old Backups Cleaned Up.${RESET}"
}



# Function to Transfer the pg_dump archive to the S3 bucket (pgBackRest uploads its own backups):
transfer_backup(){
    # Start time of the S3 transfer
    START_TRANS="$(date +%s)"

    if [ -f "${BACKUP_DIR}/${DUMP_ARCHIVE}" ]; then
        echo -e "${YELLOW}Initiating S3 Transfer For pg_dump Backup.${RESET}"

        # Upload New Backup to the S3 bucket (a multipart upload: the AWS CLI picks the part size for any file size):
        # timeout stops an upload that hangs (network stall, stuck login), so the transfer fails instead of the run hanging forever.
        # --kill-after kills aws if it ignores the stop signal. 9>&- keeps the run lock (flock) out of aws and its worker processes,
        # so a worker that survives the timeout cannot block every later run. --no-progress: one line in the log, not a progress bar:
        timeout --kill-after=1m "$UPLOAD_TIMEOUT" ${AWS_BINARY_PATH} s3 cp --no-progress \
            ${BACKUP_DIR}/${DUMP_ARCHIVE} \
            ${S3_BUCKET}/${DUMP_ARCHIVE} 9>&-

        # Check Transfer Code:
        TRANSFER_EXIT_CODE=$?
        if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Transfer to S3 Bucket Failed! (pg_dump)${RESET}"
            # timeout exits with 124 when it stopped the upload, and with 137 when it had to kill it:
            if [ $TRANSFER_EXIT_CODE -eq 124 ] || [ $TRANSFER_EXIT_CODE -eq 137 ]; then
                echo -e "${RED}The upload did not finish within ${UPLOAD_TIMEOUT} and was stopped.${RESET}"
            fi
            return 1
        else
            echo -e "${GREEN}Successfully Transferred Backup to S3 Bucket.${RESET}"
        fi

        # End Time of the Transfer.
        END_TRANS="$(date +%s)"

        # Calculate Transfer Duration:
        DURATION_TRANS="$(( ($END_TRANS - $START_TRANS) + 2 ))"
        echo "Duration in Seconds: $(($END_TRANS - $START_TRANS))"

    else
        echo "Error: The pg_dump archive ${BACKUP_DIR}/${DUMP_ARCHIVE} does not exist! Exiting."
        return 1
    fi
}



# Function to save BACKUP monitoring metrics in case of SUCCESS (METRICS_NAME: backup, incremental_backup or logical_backup):
save_backup_metrics_success() {
    # Add Success Backup Stats to Node_Exporter file:
    printf "node_postgresql_${METRICS_NAME}_status{instance=\"$SERVER_NAME\"} 0\n" > "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$"
    printf "node_postgresql_${METRICS_NAME}_duration_seconds{instance=\"$SERVER_NAME\"} $DURATION_BACKUP\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$"

    # The size of this backup in bytes (BACKUP_SIZE). A metric with an empty or non-numeric value makes node_exporter drop the whole file,
    # so skip a value that could not be read:
    if [[ "$BACKUP_SIZE" =~ ^[0-9]+$ ]]; then
        printf "node_postgresql_${METRICS_NAME}_size_bytes{instance=\"$SERVER_NAME\"} $BACKUP_SIZE\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$"
    else
        echo -e "${YELLOW}Warning: Unable to read the size of this backup, skipping node_postgresql_${METRICS_NAME}_size_bytes metric.${RESET}"
    fi

    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom"
}


# Function to save BACKUP monitoring metrics in case of FAILURE (a failed pg_dump backup is a failed transfer too: it is never uploaded):
save_backup_metrics_failure() {
    printf "node_postgresql_${METRICS_NAME}_status{instance=\"$SERVER_NAME\"} 1\n" > "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$"
    printf "node_postgresql_${METRICS_NAME}_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$"
    if [ "$METRICS_NAME" == "logical_backup" ]; then
        printf "node_postgresql_${METRICS_NAME}_transfer_status{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$"
        printf "node_postgresql_${METRICS_NAME}_transfer_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$"
    fi

    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom"
}


# Function to save the time of the last successful backup (ms) in a separate prom. file: the backup's age on the dashboards.
# For pgBackRest after the backup (it is in the repository by then), for pg_dump after the transfer:
save_backup_age() {
    printf "node_postgresql_last_successful_${METRICS_NAME}_date{instance=\"$SERVER_NAME\"} $BACKUP_TIMESTAMP\n" > "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_age.prom"
}


# Function to save TRANSFER monitoring metrics in case of SUCCESS (pg_dump only): / Update Backup Age Timestamp(ms)
save_transfer_metrics_success() {
    # Add Success Transfer Stats to Node_Exporter file:
    printf "node_postgresql_${METRICS_NAME}_transfer_status{instance=\"$SERVER_NAME\"} 0\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom"
    printf "node_postgresql_${METRICS_NAME}_transfer_duration_seconds{instance=\"$SERVER_NAME\"} $DURATION_TRANS\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom"
    save_backup_age
}


# Function to save TRANSFER monitoring metrics in case of FAILURE (pg_dump only):
save_transfer_metrics_failure() {
    # Add Failure Transfer Stats to Node_Exporter file:
    printf "node_postgresql_${METRICS_NAME}_transfer_status{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom"
    printf "node_postgresql_${METRICS_NAME}_transfer_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/postgresql_${METRICS_NAME}_status.prom"
}



function main() {
    if [ $# -ne 1 ]; then
        echo
        echo -e "${RED}Error: Exactly one argument is required (got $#).${RESET}"
        show_help
        exit 1
    fi

    # Only one backup may run at a time (cron and manual runs, local or not). The lock is released automatically when the script exits.
    # A run that finds the lock taken fails without touching the metrics: the backup that holds it still writes its own.
    # On a replica the run ends here, without metrics (see 10).
    # The log starts first, so these errors are logged too (--help and invalid options are not logged):
    case "$1" in
        --pgbackrest|--pgbackrest_incremental|--pg_dump|--pg_dump_local)
            start_log "$1"

            if [ -z "$AWS_BINARY_PATH" ] && [ "$1" == "--pg_dump" ]; then
                echo -e "${RED}Error: AWS CLI is not installed or not in PATH. Please install the AWS CLI v2.${RESET}"
            fi

            exec 9> "$LOCK_FILE" || {
                echo -e "${RED}Error: Unable to open the lock file $LOCK_FILE.${RESET}"
                exit 1; }

            if ! flock -n 9; then
                echo -e "${RED}Error: Another backup is still running (it holds $LOCK_FILE), so this one does not start.${RESET}"
                exit 1
            fi

            check_primary || exit 0
            ;;
    esac

    case "$1" in
        --pgbackrest)
            pgbackrest_backup
            if [ $? -eq 0 ]; then
                save_backup_metrics_success
                save_backup_age
                echo -e "${GREEN}Saved Success Metrics for pgBackRest Full Backup.${RESET}"
            else
                save_backup_metrics_failure
                echo -e "${RED}Saved Failure Metrics for pgBackRest Full Backup!${RESET}"
                exit 1
            fi
            ;;
        --pgbackrest_incremental)
            METRICS_NAME="incremental_backup"
            pgbackrest_incremental_backup
            if [ $? -eq 0 ]; then
                save_backup_metrics_success
                save_backup_age
                echo -e "${GREEN}Saved Success Metrics for pgBackRest Incremental Backup.${RESET}"
            else
                save_backup_metrics_failure
                echo -e "${RED}Saved Failure Metrics for pgBackRest Incremental Backup!${RESET}"
                exit 1
            fi
            ;;
        --pg_dump)
            METRICS_NAME="logical_backup"
            pg_dump_backup
            if [ $? -eq 0 ]; then
                save_backup_metrics_success
                echo -e "${GREEN}Saved Success Metrics for pg_dump Backup.${RESET}"
            else
                save_backup_metrics_failure
                echo -e "${RED}Saved Failure Metrics for pg_dump Backup!${RESET}"
                exit 1
            fi
            manage_old_backups
            transfer_backup
            if [ $? -eq 0 ]; then
                save_transfer_metrics_success
                echo -e "${GREEN}Saved Successful Transfer Metrics for pg_dump Backup.${RESET}"
            else
                save_transfer_metrics_failure
                echo -e "${RED}Saved Failed Transfer Metrics for pg_dump Backup!${RESET}"
                exit 1
            fi
            ;;
        --pg_dump_local)
            pg_dump_backup
            if [ $? -eq 0 ]; then
                echo -e  "${GREEN}Local pg_dump Backup Finished Successfully.${RESET}"
            else
                echo -e  "${RED}Local pg_dump Backup Failed!${RESET}"
                exit 1
            fi
            ;;
        --help)
            show_help
            ;;
        *)
            echo
            echo -e "${RED}Error: Invalid argument '$1'.${RESET}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

