#!/bin/bash

set -uo pipefail

# No core dumps: a crashing xtrabackup would write its memory, and the encryption key in it, to disk (systemd-coredump):
ulimit -c 0

# Main script for exporting LOGICAL and PHYSICAL production DB backups. (Version 3, AWS)
# The AWS version of mysql_backup_v3.sh: the same backup logic, with the upload to Amazon S3 instead of a GCP bucket.
# 1) Uses Percona (MySQL Shell) or Percona (XtraBackup) to make a full instance backup.
# 2) Holds the MySQL named lock 'backup_running' during the backup: the application's TRUNCATE scripts check it and do not run while it is held.
# 3) Releases the lock upon backup completion / failure / interruption. A file lock (flock) keeps a second run of this script from starting.
# 4) Transfers the backup to an S3 bucket, with a time limit (UPLOAD_TIMEOUT). The AWS CLI takes its credentials from the server's IAM role.
# 5) Updates node_exporter text collector files for Grafana backup monitoring in case of SUCCESS or FAILURE.
# 6) Backups can be performed LOCALLY by both utilities if needed.
# 7) Logs every backup run (normal execution and errors, with colors) to /var/log/mysql_backup.log. Before the script runs from cron,
#    install its rotation: cp mysql_backup.logrotate.example /etc/logrotate.d/mysql_backup (the log grows without it).
#    The script logs itself, so cron's copy of the output goes to /dev/null, e.g. in /etc/cron.d/mysql_backup (full backups on Monday
#    and Thursday, incremental backups on the other days):
#    0 2 * * 1,4 root /opt/scripts/mysql_backup_v3_aws.sh --xtrabackup > /dev/null 2>&1
#    0 2 * * 0,2,3,5,6 root /opt/scripts/mysql_backup_v3_aws.sh --xtrabackup_incremental > /dev/null 2>&1
# 8) Encrypts the XtraBackup backups (AES256) with a key read from AWS Secrets Manager. The key is kept on the RAM disk (/dev/shm)
#    for the backup only, and never printed. To restore: xbstream -x < <backup>.xbstream, then
#    xtrabackup --decrypt=AES256 --encrypt-key-file=<file with the key> --decompress --remove-original --target-dir=<dir>, then --prepare.
# 9) Incremental XtraBackup backups in a chain (--xtrabackup_incremental): each one holds only the pages changed since the backup before it
#    (the full backup, or the incremental before it). A full backup (--xtrabackup) starts a new chain. To restore: decrypt every backup
#    of the chain as in 8), then xtrabackup --prepare --apply-log-only --target-dir=<full>, then for each incremental in order
#    xtrabackup --prepare --apply-log-only --target-dir=<full> --incremental-dir=<incremental> (the last one without --apply-log-only).
#    Bucket retention: to restore any moment of the last N days, keep every backup N + 4 days. A restore point can need a full backup
#    up to 4 days older than itself (Thursday's full, then three incrementals and a day of binlogs).


# Colors for output:
WHITE="\e[1m"
GREEN="\e[32m"
CYAN="\e[36m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

# Variables:
CURRENT_TIME=`date +%Y-%m-%d-%H%M%S`
DATA_DIR="/var/lib/mysql"
BACKUP_DIR="/backup"
BACKUP_DIR_SHELL="${BACKUP_DIR}/full-instance-backup-${CURRENT_TIME}-mysql-shell/"
# The file of this run's XtraBackup backup (--xtrabackup_incremental changes it to <time>-dbincr.xbstream):
XTRABACKUP_FILE="${CURRENT_TIME}-dbfull.xbstream"
# The state of the incremental backup chain: xtrabackup_checkpoints (the LSN) of the last backup uploaded to the bucket, the base of the
# next --xtrabackup_incremental. Delete it only to stop the chain: --xtrabackup_incremental then fails until a full backup (--xtrabackup) runs:
LSN_DIR="/opt/scripts/mysql_backup.state"
# Each XtraBackup run writes its own LSN folder here, and it replaces LSN_DIR only after the backup is in the bucket:
NEW_LSN_DIR="/opt/scripts/mysql_backup.state.new"
# Empty if the AWS CLI is not installed: main reports it once the log has started.
AWS_BINARY_PATH=$(which aws 2>/dev/null)
# Set the S3 bucket and folder of this server before the first run (in the aws-dba-labs lab: terraform output backup_s3_prefix):
S3_BUCKET="s3://BUCKET/mysql"
# The AWS Secrets Manager secret with the encryption key (32 characters). Set the secret of this server before the first run
# (the value below is the aws-dba-labs lab's secret). Without this key the backups cannot be restored:
ENCRYPTION_KEY_SECRET="mysql-single/backup-encryption-key"
# Set by fetch_encryption_key for the duration of the backup:
ENCRYPTION_KEY_FILE=""
TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector/"
# The name in the metrics and their files: backup for full backups, incremental_backup for --xtrabackup_incremental (set in main),
# so each has its own status, durations and age, e.g. node_mysql_incremental_backup_status in mysql_incremental_backup_status.prom:
METRICS_NAME="backup"
LOCK_FILE="/var/lock/mysql_backup.lock"
LOG_FILE="/var/log/mysql_backup.log"
# An upload that takes longer is stopped and the transfer fails. Keep it well above the slowest normal upload (node_mysql_backup_transfer_duration_seconds):
UPLOAD_TIMEOUT="12h"
BACKUP_TIMESTAMP=$(($(date +%s) * 1000))


# Function Help:
show_help() {
    echo "================================================================================================================================="
    echo
    echo -e "${GREEN}Available Backup Options:${RESET} 🔧"
    echo
    echo -e "  ${CYAN}--xtrabackup${RESET}              | Backup the DB instance using Percona XtraBackup (encrypted) and transfer to the S3 bucket."
    echo -e "                              | It starts a new chain for --xtrabackup_incremental."
    echo -e "  ${CYAN}--xtrabackup_incremental${RESET}  | Incremental backup using Percona XtraBackup (encrypted): only the pages changed since the last backup"
    echo -e "                              | of the chain, transferred to the S3 bucket. It fails until a full backup (--xtrabackup) starts a chain."
    echo -e "  ${CYAN}--mysql_shell${RESET}             | Backup the DB instance using Percona MySQL Shell and transfer to the S3 bucket."
    echo -e "  ${CYAN}--xtrabackup_local${RESET}        | Perform a local backup using Percona XtraBackup (encrypted)."
    echo -e "  ${CYAN}--mysql_shell_local${RESET}       | Perform a local backup using Percona MySQL Shell."
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




# Function to check if machine host is (src) or (rpl):
check_host(){

    rpl_env_type=`hostname -s | awk -F"-" '{print $(NF)}'`
    case "$rpl_env_type" in
        rpl??|src)
            SERVER_NAME=$(hostname -s)
            ;;
        *)
            SERVER_NAME=$(hostname -s | cut -d"-" -f1-4)
            ;;
    esac
}



# Function to take the MySQL named lock 'backup_running' for the duration of the backup (the application's TRUNCATE scripts check it):
acquire_backup_lock(){
    BACKUP_LOCK_NAME="backup_running"

    echo -e "${YELLOW}-- Attempting to acquire database lock named: ${BACKUP_LOCK_NAME} --${RESET}"

    # The lock session writes its answers to this file (--unbuffered: at once), so the script can read whether GET_LOCK succeeded:
    local LOCK_ANSWER_FILE
    LOCK_ANSWER_FILE=$(mktemp -t mysql_backup_lock.XXXXXX) || {
        echo -e "${RED}-- Error: Unable to create a temporary file for the lock session. --${RESET}"
        return 1; }

    # Start a background process to hold the lock: a mysql session that ends, and releases the lock, when its input (fd 3) is closed.
    # xtrabackup / mysqlsh inherit fd 3, so if this script is killed the lock stays held until the backup tool has finished too:
    exec 3> >(mysql --login-path=local -N --unbuffered > "$LOCK_ANSWER_FILE")
    local LOCK_SESSION_PID="${!:-}"

    # Bump the timeouts for THIS SESSION ONLY (12 hours = 43200 seconds), so the idle session is not disconnected during a long backup.
    # GET_LOCK(...,0) takes the lock or returns 0 at once: checking and taking it is one step, so two sessions can never both get it.
    # SIGPIPE is ignored for this one write, so a session that already died (wrong login, MySQL down) cannot kill the script:
    trap '' PIPE
    echo "SET SESSION wait_timeout=43200; SET SESSION interactive_timeout=43200; SELECT GET_LOCK('${BACKUP_LOCK_NAME}',0);" >&3 2>/dev/null
    trap - PIPE

    # Wait up to 60 s for the answer, and stop early if the session has already ended (MySQL prints its error above):
    local LOCK_RESULT="" WAITED=0
    while [ "$WAITED" -lt 600 ]; do
        read -r LOCK_RESULT < "$LOCK_ANSWER_FILE"
        [ -n "$LOCK_RESULT" ] && break
        [ -n "$LOCK_SESSION_PID" ] && ! kill -0 "$LOCK_SESSION_PID" 2>/dev/null && break
        sleep 0.1
        WAITED=$((WAITED + 1))
    done
    rm -f "$LOCK_ANSWER_FILE"

    if [ "$LOCK_RESULT" != "1" ]; then
        if [ "$LOCK_RESULT" == "0" ]; then
            echo -e "${RED}-- Error: Could not acquire lock: ${BACKUP_LOCK_NAME} is held by another session (another backup, or an application TRUNCATE script). --${RESET}"
        else
            echo -e "${RED}-- Error: Could not acquire lock: no answer from MySQL to GET_LOCK (got: '${LOCK_RESULT}'). See the MySQL error above, if any. --${RESET}"
        fi
        release_backup_lock
        return 1
    fi

    # Setup Trap for safety | If the script exits / is interrupted / or is killed, close the session to release the lock,
    # and remove the encryption key from the RAM disk:
    trap 'remove_encryption_key; release_backup_lock; echo -e "${RED}-- Lock released by trap. --${RESET}"' EXIT INT TERM

    echo -e "${GREEN}-- Lock acquired successfully. --${RESET}"
}


# Function to release the MySQL named lock: closing fd 3 ends the lock session, and MySQL releases the lock with it (safe to call twice):
release_backup_lock(){
    exec 3>&-
}



# Function to read the encryption key from AWS Secrets Manager into a file on the RAM disk (/dev/shm), for this backup only.
# xtrabackup reads the key only from a file (--encrypt-key-file): on the RAM disk it never reaches a disk, and mktemp makes the file
# readable by root only. The key never goes on a command line (ps shows those to every user) and is never printed, so it stays out of the log:
fetch_encryption_key(){
    if [ -z "$AWS_BINARY_PATH" ]; then
        echo -e "${RED}Error: AWS CLI is not installed or not in PATH: the encryption key cannot be read from AWS Secrets Manager.${RESET}"
        return 1
    fi

    local ENCRYPTION_KEY
    ENCRYPTION_KEY=$(${AWS_BINARY_PATH} secretsmanager get-secret-value --secret-id "$ENCRYPTION_KEY_SECRET" --query SecretString --output text) || {
        echo -e "${RED}Error: Unable to read the encryption key $ENCRYPTION_KEY_SECRET from AWS Secrets Manager.${RESET}"
        return 1; }

    # AES256 needs a key of exactly 32 characters (xtrabackup would fail with an invalid key length):
    if [ ${#ENCRYPTION_KEY} -ne 32 ]; then
        echo -e "${RED}Error: The encryption key $ENCRYPTION_KEY_SECRET has ${#ENCRYPTION_KEY} characters instead of 32.${RESET}"
        return 1
    fi

    ENCRYPTION_KEY_FILE=$(mktemp -p /dev/shm mysql_backup_key.XXXXXX) || {
        echo -e "${RED}Error: Unable to create the encryption key file on the RAM disk /dev/shm.${RESET}"
        return 1; }

    # printf is built into bash: the key is written to the file without ever being on a command line:
    printf '%s' "$ENCRYPTION_KEY" > "$ENCRYPTION_KEY_FILE"
    echo -e "${GREEN}-- Encryption key read from AWS Secrets Manager ($ENCRYPTION_KEY_SECRET). --${RESET}"
}


# Function to remove the encryption key file from the RAM disk (safe to call twice, and when there is no key file):
remove_encryption_key(){
    [ -n "$ENCRYPTION_KEY_FILE" ] && rm -f "$ENCRYPTION_KEY_FILE"
    ENCRYPTION_KEY_FILE=""
}



# Function for MySQL Shell Backup:
mysql_shell_backup(){

    command -v mysqlsh >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        acquire_backup_lock || return 1
        echo -e "${YELLOW}Starting MySQL Shell Backup at ${CURRENT_TIME} ${RESET}"

        # Start time of the backup script:
        START_BACKUP="$(date +%s)"

        # Perform a full instance backup with MySQL Shell: // Ensures consistency without locking!
        mysqlsh --login-path=local -S /var/lib/mysql/mysql.sock --js <<EOF
        util.dumpInstance('${BACKUP_DIR_SHELL}', {
        bytesPerChunk: '100M',
        threads: 4,
        compatibility: ['strip_invalid_grants'] })
EOF
        # Save Backup Exit Code:
        MYSQL_SHELL_EXIT_CODE=$?

        # Release the lock (closing the input of the lock session ends it) and clear the trap:
        release_backup_lock && \
        trap - EXIT INT TERM && \
        echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"

        if [ $MYSQL_SHELL_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}MySQL Shell Backup Failed!${RESET}"
            return 1
        fi

        # Archive the MySQL Shell backup folder without compressing it again: the dump files are already compressed (zstd).
        # The relative name stores the folder as full-instance-backup-<time>-mysql-shell/ instead of under its full path:
        cd ${BACKUP_DIR} && time tar -cf full-instance-backup-${CURRENT_TIME}.tar full-instance-backup-${CURRENT_TIME}-mysql-shell

        # Save Tar exit code:
        FOLDER_ARCHIVE_STATUS=$?
        if [ $FOLDER_ARCHIVE_STATUS -ne 0 ]; then
            echo -e "${RED}Backup Folder Archive Failed!${RESET}"
            return 1
        fi

        # End time of the backup script:
        END_BACKUP="$(date +%s)"

        # Calculate backup duration:
        DURATION_BACKUP="$(( ($END_BACKUP - $START_BACKUP) + 2 ))"
        echo
        echo -e "${YELLOW}Duration in Seconds:${RESET} $(($END_BACKUP - $START_BACKUP))"
        return 0  # Success

    else
        echo -e "${RED}Percona MySQL Shell is not installed.${RESET}"
        return 1  # Failure
    fi
}



# Function for XtraBackup Backup:
xtrabackup_backup() {
    if command -v xtrabackup >/dev/null 2>&1; then
        acquire_backup_lock || return 1
        echo -e "${YELLOW}Starting XtraBackup at ${CURRENT_TIME} ${RESET}"

        # Start time of the backup script:
        START_BACKUP="$(date +%s)"

        # Go to BACKUP_DIR:
        cd ${BACKUP_DIR} || { echo -e "${RED}Error: Failed to change directory to ${BACKUP_DIR} ${RESET}"; return 1; }

        # Read the encryption key for this backup (the lock's trap removes it if the script is stopped):
        fetch_encryption_key || {
            release_backup_lock && \
            trap - EXIT INT TERM && \
            echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"
            return 1; }

        # Run XtraBackup and check for failure. Every file is compressed, then encrypted (AES256) with the key file on the RAM disk.
        # --extra-lsndir also writes xtrabackup_checkpoints (the LSN) to NEW_LSN_DIR: once uploaded, this backup starts a new chain:
        rm -rf "${NEW_LSN_DIR}"
        xtrabackup --backup --datadir="${DATA_DIR}" --stream=xbstream --throttle=60 --parallel=8 --compress \
            --compress-zstd-level=1 --compress-threads=8 --encrypt=AES256 --encrypt-key-file="${ENCRYPTION_KEY_FILE}" \
            --encrypt-threads=8 --extra-lsndir="${NEW_LSN_DIR}" --login-path=local \
            > "${BACKUP_DIR}/${XTRABACKUP_FILE}"

        # Save Backup Exit Code:
        XTRABACKUP_EXIT_CODE=$?

        # The backup no longer needs the key: remove it from the RAM disk.
        remove_encryption_key

        # Release the lock (closing the input of the lock session ends it) and clear the trap:
        release_backup_lock && \
        trap - EXIT INT TERM && \
        echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"

        if [ $XTRABACKUP_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}XtraBackup failed.${RESET}"
            return 1
        fi

        # End time of the backup script.
        END_BACKUP="$(date +%s)"

        # Calculate backup duration:
        DURATION_BACKUP="$(( ($END_BACKUP - $START_BACKUP) + 2 ))"
        echo
        echo -e "${YELLOW}Duration in Seconds:${RESET} $(($END_BACKUP - $START_BACKUP))"
        return 0

    else
        echo -e "${RED}Percona XtraBackup is not installed.${RESET}"
        return 1
    fi
}



# Function for an incremental XtraBackup Backup in a chain: only the pages changed since the last backup in the bucket (LSN_DIR):
xtrabackup_incremental_backup() {
    if command -v xtrabackup >/dev/null 2>&1; then

        # Without a base there is no chain to continue: a person takes a full backup (--xtrabackup), which starts a new chain:
        if [ ! -f "${LSN_DIR}/xtrabackup_checkpoints" ]; then
            echo -e "${RED}Error: No base for the incremental backup: ${LSN_DIR}/xtrabackup_checkpoints does not exist. Take a full backup first (--xtrabackup).${RESET}"
            return 1
        fi

        XTRABACKUP_FILE="${CURRENT_TIME}-dbincr.xbstream"
        acquire_backup_lock || return 1
        echo -e "${YELLOW}Starting Incremental XtraBackup at ${CURRENT_TIME} from $(grep '^to_lsn' "${LSN_DIR}/xtrabackup_checkpoints") ${RESET}"

        # Start time of the backup script:
        START_BACKUP="$(date +%s)"

        # Go to BACKUP_DIR:
        cd ${BACKUP_DIR} || { echo -e "${RED}Error: Failed to change directory to ${BACKUP_DIR} ${RESET}"; return 1; }

        # Read the encryption key for this backup (the lock's trap removes it if the script is stopped):
        fetch_encryption_key || {
            release_backup_lock && \
            trap - EXIT INT TERM && \
            echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"
            return 1; }

        # Run XtraBackup as for the full backup, plus --incremental-basedir: it copies only the pages changed after the LSN in LSN_DIR.
        # --extra-lsndir writes this backup's LSN to NEW_LSN_DIR: once uploaded, it is the base of the next incremental:
        rm -rf "${NEW_LSN_DIR}"
        xtrabackup --backup --datadir="${DATA_DIR}" --stream=xbstream --throttle=60 --parallel=8 --compress \
            --compress-zstd-level=1 --compress-threads=8 --encrypt=AES256 --encrypt-key-file="${ENCRYPTION_KEY_FILE}" \
            --encrypt-threads=8 --incremental-basedir="${LSN_DIR}" --extra-lsndir="${NEW_LSN_DIR}" --login-path=local \
            > "${BACKUP_DIR}/${XTRABACKUP_FILE}"

        # Save Backup Exit Code:
        XTRABACKUP_EXIT_CODE=$?

        # The backup no longer needs the key: remove it from the RAM disk.
        remove_encryption_key

        # Release the lock (closing the input of the lock session ends it) and clear the trap:
        release_backup_lock && \
        trap - EXIT INT TERM && \
        echo -e "${YELLOW}-- Lock named ${BACKUP_LOCK_NAME} has been released and trap removed. --${RESET}"

        if [ $XTRABACKUP_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Incremental XtraBackup failed.${RESET}"
            return 1
        fi

        # End time of the backup script.
        END_BACKUP="$(date +%s)"

        # Calculate backup duration:
        DURATION_BACKUP="$(( ($END_BACKUP - $START_BACKUP) + 2 ))"
        echo
        echo -e "${YELLOW}Duration in Seconds:${RESET} $(($END_BACKUP - $START_BACKUP))"
        return 0

    else
        echo -e "${RED}Percona XtraBackup is not installed.${RESET}"
        return 1
    fi
}



# Function to Delete old local backups (MySQL Shell archives: .tar, and .tar.gz from v2):
manage_old_backups() {
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type d  -name 'full-instance-backup*' -mtime +0 -exec rm -rfv {} \;
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type f  -name 'full-instance-backup*.tar*' -mtime +2 -exec rm -rfv {} \;
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type f  -name '*.xbstream' -mmin +1380 -exec rm -fv {} \;
    echo -e "${GREEN}Old Backups Cleaned Up.${RESET}"
}



# Function to Transfer MySQL Shell or XtraBackup to the S3 bucket:
transfer_backup(){
    # Start time of the S3 transfer
    START_TRANS="$(date +%s)"

    ############## INITIATE MYSQL_SHELL BACKUP TRANSFER ##############
    if [ -d "$BACKUP_DIR_SHELL" ]; then
        echo -e "${YELLOW}Initiating S3 Transfer For MySQL Shell Backup.${RESET}"

        # Upload New Backup to the S3 bucket (a multipart upload: the AWS CLI picks the part size for any file size):
        # timeout stops an upload that hangs (network stall, stuck login), so the transfer fails instead of the run hanging forever.
        # --kill-after kills aws if it ignores the stop signal. 9>&- keeps the run lock (flock) out of aws and its worker processes,
        # so a worker that survives the timeout cannot block every later run. --no-progress: one line in the log, not a progress bar:
        timeout --kill-after=1m "$UPLOAD_TIMEOUT" ${AWS_BINARY_PATH} s3 cp --no-progress \
            ${BACKUP_DIR}/full-instance-backup-${CURRENT_TIME}.tar \
            ${S3_BUCKET}/full-instance-backup-${CURRENT_TIME}.tar 9>&-

        # Check Transfer Code:
        TRANSFER_EXIT_CODE=$?
        if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Transfer to S3 Bucket Failed! (MySQL Shell)${RESET}"
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



    #################### INITIATE XTRABACKUP TRANSFER ####################
    elif [ -f "${BACKUP_DIR}/${XTRABACKUP_FILE}" ]; then

        echo -e "${YELLOW}Initiating S3 Transfer For XtraBackup.${RESET}"

        # Upload New Backup (full or incremental) to the S3 bucket (time limit, 9>&- and --no-progress as for the MySQL Shell upload above):
        timeout --kill-after=1m "$UPLOAD_TIMEOUT" ${AWS_BINARY_PATH} s3 cp --no-progress \
            ${BACKUP_DIR}/${XTRABACKUP_FILE}  \
            ${S3_BUCKET}/${XTRABACKUP_FILE} 9>&-


        # Check Transfer Code:
        TRANSFER_EXIT_CODE=$?
        if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Transfer to S3 Bucket Failed! (XtraBackup)${RESET}"
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
        echo "Error: Neither Backup Directory Exists! Exiting."
        return 1
    fi
}


# Function to move the incremental backup chain forward once the backup is in the bucket: its LSN folder replaces LSN_DIR and is the base
# of the next --xtrabackup_incremental. A failed backup or upload never gets here, so the chain stays on the last backup in the bucket:
advance_backup_chain(){
    rm -rf "${LSN_DIR}" && mv "${NEW_LSN_DIR}" "${LSN_DIR}" || {
        echo -e "${RED}Error: Unable to move ${NEW_LSN_DIR} to ${LSN_DIR}: the next incremental backup has no base until a full backup runs.${RESET}"
        return 1; }
    echo -e "${GREEN}-- Backup chain moved forward: the next incremental starts from $(grep '^to_lsn' "${LSN_DIR}/xtrabackup_checkpoints"). --${RESET}"
}



# Function to save BACKUP monitoring metrics in case of SUCCESS (METRICS_NAME: backup or incremental_backup):
save_backup_metrics_success() {
    # Add Success Backup Stats to Node_Exporter file:
    printf "node_mysql_${METRICS_NAME}_status{instance=\"$SERVER_NAME\"} 0\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$"
    printf "node_mysql_${METRICS_NAME}_duration_seconds{instance=\"$SERVER_NAME\"} $DURATION_BACKUP\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$"

    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom"
}


# Function to save BACKUP monitoring metrics in case of FAILURE:
save_backup_metrics_failure() {
    printf "node_mysql_${METRICS_NAME}_status{instance=\"$SERVER_NAME\"} 1\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$"
    printf "node_mysql_${METRICS_NAME}_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$"
    printf "node_mysql_${METRICS_NAME}_transfer_status{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$"
    printf "node_mysql_${METRICS_NAME}_transfer_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$"

    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom"
}


# Function to save TRANSFER monitoring metrics in case of SUCCESS: / Update Backup Age Timestamp(ms) in a separate prom. file
save_transfer_metrics_success() {
    # Add Success Transfer Stats to Node_Exporter file:
    printf "node_mysql_${METRICS_NAME}_transfer_status{instance=\"$SERVER_NAME\"} 0\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom"
    printf "node_mysql_${METRICS_NAME}_transfer_duration_seconds{instance=\"$SERVER_NAME\"} $DURATION_TRANS\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom"
    printf "node_mysql_last_successful_${METRICS_NAME}_date{instance=\"$SERVER_NAME\"} $BACKUP_TIMESTAMP\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_age.prom"
}


# Function to save TRANSFER monitoring metrics in case of FAILURE:
save_transfer_metrics_failure() {
    # Add Failure Transfer Stats to Node_Exporter file:
    printf "node_mysql_${METRICS_NAME}_transfer_status{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom"
    printf "node_mysql_${METRICS_NAME}_transfer_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_${METRICS_NAME}_status.prom"
}



function main() {
    if [ $# -ne 1 ]; then
        echo
        echo -e "${RED}Error: Exactly one argument is required (got $#).${RESET}"
        show_help
        exit 1
    fi

    check_host

    # Only one backup may run at a time (cron and manual runs, local or not). The lock is released automatically when the script exits.
    # A run that finds the lock taken fails without touching the metrics: the backup that holds it still writes its own.
    # The log starts first, so these errors are logged too (--help and invalid options are not logged):
    case "$1" in
        --mysql_shell|--xtrabackup|--xtrabackup_incremental|--mysql_shell_local|--xtrabackup_local)
            start_log "$1"

            if [ -z "$AWS_BINARY_PATH" ] && [[ "$1" != *_local ]]; then
                echo -e "${RED}Error: AWS CLI is not installed or not in PATH. Please install the AWS CLI v2.${RESET}"
            fi

            exec 9> "$LOCK_FILE" || {
                echo -e "${RED}Error: Unable to open the lock file $LOCK_FILE.${RESET}"
                exit 1; }

            if ! flock -n 9; then
                echo -e "${RED}Error: Another backup is still running (it holds $LOCK_FILE), so this one does not start.${RESET}"
                exit 1
            fi
            ;;
    esac

    case "$1" in
        --mysql_shell)
            mysql_shell_backup
            if [ $? -eq 0 ]; then
                save_backup_metrics_success
                echo -e "${GREEN}Saved Success Metrics for MySQL Shell Backup.${RESET}"
            else
                save_backup_metrics_failure
                echo -e "${RED}Saved Failure Metrics for MySQL Shell Backup!${RESET}"
                exit 1
            fi
            manage_old_backups
            transfer_backup
            if [ $? -eq 0 ]; then
                save_transfer_metrics_success
                echo -e "${GREEN}Saved Successful Transfer Metrics for MySQL Shell Backup.${RESET}"
            else
                save_transfer_metrics_failure
                echo -e "${RED}Saved Failed Transfer Metrics for MySQL Shell Backup!${RESET}"
                exit 1
            fi
            ;;
        --xtrabackup)
            xtrabackup_backup
            if [ $? -eq 0 ]; then
                save_backup_metrics_success
                echo -e "${GREEN}Saved Success Metrics for XtraBackup Process.${RESET}"
            else
                save_backup_metrics_failure
                echo -e "${RED}Saved Failure Metrics for XtraBackup Process!${RESET}"
                exit 1
            fi
            manage_old_backups
            # Once the backup is in the bucket, it starts a new chain for --xtrabackup_incremental:
            transfer_backup && advance_backup_chain
            if [ $? -eq 0 ]; then
                save_transfer_metrics_success
                echo -e "${GREEN}Saved Successful Transfer Metrics for XtraBackup.${RESET}"
            else
                save_transfer_metrics_failure
                echo -e "${RED}Saved Failed Transfer Metrics for XtraBackup!${RESET}"
                exit 1
            fi
            ;;
        --xtrabackup_incremental)
            METRICS_NAME="incremental_backup"
            xtrabackup_incremental_backup
            if [ $? -eq 0 ]; then
                save_backup_metrics_success
                echo -e "${GREEN}Saved Success Metrics for Incremental XtraBackup Process.${RESET}"
            else
                save_backup_metrics_failure
                echo -e "${RED}Saved Failure Metrics for Incremental XtraBackup Process!${RESET}"
                exit 1
            fi
            manage_old_backups
            # Once the backup is in the bucket, it is the base of the next incremental:
            transfer_backup && advance_backup_chain
            if [ $? -eq 0 ]; then
                save_transfer_metrics_success
                echo -e "${GREEN}Saved Successful Transfer Metrics for Incremental XtraBackup.${RESET}"
                # The incremental backup is in the bucket, so it is not kept on the local disk (a failed upload keeps it until manage_old_backups):
                rm -fv "${BACKUP_DIR}/${XTRABACKUP_FILE}"
            else
                save_transfer_metrics_failure
                echo -e "${RED}Saved Failed Transfer Metrics for Incremental XtraBackup!${RESET}"
                exit 1
            fi
            ;;
        --xtrabackup_local)
            xtrabackup_backup
            if [ $? -eq 0 ]; then
                echo -e  "${GREEN}Local XtraBackup Finished Successfully.${RESET}"
            else
                echo -e  "${RED}Local XtraBackup Failed!${RESET}"
                exit 1
            fi
            ;;
        --mysql_shell_local)
            mysql_shell_backup
            if [ $? -eq 0 ]; then
                echo -e  "${GREEN}Local MySQL Shell Backup Finished Successfully.${RESET}"
            else
                echo -e  "${RED}Local MySQL Shell Backup Failed!${RESET}"
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


