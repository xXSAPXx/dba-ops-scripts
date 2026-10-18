#!/bin/bash

set -uo pipefail

# Main script for exporting LOGICAL and PHYSICAL production DB backups. (Version 3)
# 1) Uses Percona (MySQL Shell) or Percona (XtraBackup) to make a full instance backup.
# 2) Holds the MySQL named lock 'backup_running' during the backup: the application's TRUNCATE scripts check it and do not run while it is held.
# 3) Releases the lock upon backup completion / failure / interruption. A file lock (flock) keeps a second run of this script from starting.
# 4) Transfers the backup to specific GCP Bucket, with a time limit (UPLOAD_TIMEOUT).
# 5) Updates node_exporter text collector files for Grafana backup monitoring in case of SUCCESS or FAILURE.
# 6) Backups can be performed LOCALLY by both utilities if needed.
# 7) Logs every backup run (normal execution and errors, with colors) to /var/log/mysql_backup.log. Rotation: mysql_backup.logrotate.example.
#    The script logs itself, so cron's copy of the output goes to /dev/null, e.g. in /etc/cron.d/mysql_backup:
#    0 2 * * * root /opt/scripts/mysql_backup_v3.sh --xtrabackup > /dev/null 2>&1


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
# Empty if gcloud is not installed: main reports it once the log has started.
GCP_BINARY_PATH=$(which gcloud 2>/dev/null)
GCP_BUCKET="gs://db-dela-gamification-dev-src-backup"
TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector/"
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
    echo -e "  ${CYAN}--xtrabackup${RESET}           | Backup the DB instance using Percona XtraBackup and transfer to GCP Bucket."
    echo -e "  ${CYAN}--mysql_shell${RESET}          | Backup the DB instance using Percona MySQL Shell and transfer to GCP Bucket."
    echo -e "  ${CYAN}--xtrabackup_local${RESET}     | Perform a local backup using Percona XtraBackup."
    echo -e "  ${CYAN}--mysql_shell_local${RESET}    | Perform a local backup using Percona MySQL Shell."
    echo -e "  ${CYAN}--help${RESET}                 | Display this help message."
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

    # Setup Trap for safety | If the script exits / is interrupted / or is killed, close the session to release the lock:
    trap 'release_backup_lock; echo -e "${RED}-- Lock released by trap. --${RESET}"' EXIT INT TERM

    echo -e "${GREEN}-- Lock acquired successfully. --${RESET}"
}


# Function to release the MySQL named lock: closing fd 3 ends the lock session, and MySQL releases the lock with it (safe to call twice):
release_backup_lock(){
    exec 3>&-
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

        # Run XtraBackup and check for failure
        xtrabackup --backup --datadir="${DATA_DIR}" --stream=xbstream --throttle=60 --parallel=8 --compress \
            --compress-zstd-level=1 --compress-threads=8 --login-path=local \
            > "${BACKUP_DIR}/${CURRENT_TIME}-dbfull.xbstream"

        # Save Backup Exit Code:
        XTRABACKUP_EXIT_CODE=$?

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



# Function to Delete old local backups (MySQL Shell archives: .tar, and .tar.gz from v2):
manage_old_backups() {
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type d  -name 'full-instance-backup*' -mtime +0 -exec rm -rfv {} \;
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type f  -name 'full-instance-backup*.tar*' -mtime +2 -exec rm -rfv {} \;
    time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type f  -name '*.xbstream' -mmin +1380 -exec rm -fv {} \;
    echo -e "${GREEN}Old Backups Cleaned Up.${RESET}"
}



# Function to Transfer MySQL Shell or XtraBackup to GCP Bucket:
transfer_backup(){
    # Start time of the GCP Bucket transfer
    START_TRANS="$(date +%s)"

    ############## INITIATE MYSQL_SHELL BACKUP TRANSFER ##############
    if [ -d "$BACKUP_DIR_SHELL" ]; then
        echo -e "${YELLOW}Initiating GCP Bucket Transfer For MySQL Shell Backup.${RESET}"

        # Upload New Backup to GCP Bucket:
        # timeout stops an upload that hangs (network stall, stuck login), so the transfer fails instead of the run hanging forever.
        # --kill-after kills gcloud if it ignores the stop signal. 9>&- keeps the run lock (flock) out of gcloud and its worker processes,
        # so a worker that survives the timeout cannot block every later run:
        timeout --kill-after=1m "$UPLOAD_TIMEOUT" ${GCP_BINARY_PATH} storage cp \
            ${BACKUP_DIR}/full-instance-backup-${CURRENT_TIME}.tar \
            ${GCP_BUCKET}/full-instance-backup-${CURRENT_TIME}.tar 9>&-

        # Check Transfer Code:
        TRANSFER_EXIT_CODE=$?
        if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Transfer to GCP Bucket Failed! (MySQL Shell)${RESET}"
            # timeout exits with 124 when it stopped the upload, and with 137 when it had to kill it:
            if [ $TRANSFER_EXIT_CODE -eq 124 ] || [ $TRANSFER_EXIT_CODE -eq 137 ]; then
                echo -e "${RED}The upload did not finish within ${UPLOAD_TIMEOUT} and was stopped.${RESET}"
            fi
            return 1
        else
            echo -e "${GREEN}Successfully Transferred Backup to GCP Bucket.${RESET}"
        fi

        # End Time of the Transfer.
        END_TRANS="$(date +%s)"

        # Calculate Transfer Duration:
        DURATION_TRANS="$(( ($END_TRANS - $START_TRANS) + 2 ))"
        echo "Duration in Seconds: $(($END_TRANS - $START_TRANS))"



    #################### INITIATE XTRABACKUP TRANSFER ####################
    elif [ -f "${BACKUP_DIR}/${CURRENT_TIME}-dbfull.xbstream" ]; then

        echo -e "${YELLOW}Initiating GCP Bucket Transfer For XtraBackup.${RESET}"

        # Upload New Backup to GCP Bucket (time limit and 9>&- as for the MySQL Shell upload above):
        timeout --kill-after=1m "$UPLOAD_TIMEOUT" ${GCP_BINARY_PATH} storage cp \
            ${BACKUP_DIR}/${CURRENT_TIME}-dbfull.xbstream  \
            ${GCP_BUCKET}/${CURRENT_TIME}-dbfull.xbstream 9>&-


        # Check Transfer Code:
        TRANSFER_EXIT_CODE=$?
        if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Transfer to GCP Bucket Failed! (XtraBackup)${RESET}"
            # timeout exits with 124 when it stopped the upload, and with 137 when it had to kill it:
            if [ $TRANSFER_EXIT_CODE -eq 124 ] || [ $TRANSFER_EXIT_CODE -eq 137 ]; then
                echo -e "${RED}The upload did not finish within ${UPLOAD_TIMEOUT} and was stopped.${RESET}"
            fi
            return 1
        else
            echo -e "${GREEN}Successfully Transferred Backup to GCP Bucket.${RESET}"
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



# Function to save BACKUP monitoring metrics in case of SUCCESS:
save_backup_metrics_success() {
    # Add Success Backup Stats to Node_Exporter file:
    printf "node_mysql_backup_status{instance=\"$SERVER_NAME\"} 0\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$"
    printf "node_mysql_backup_duration_seconds{instance=\"$SERVER_NAME\"} $DURATION_BACKUP\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$"

    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom"
}


# Function to save BACKUP monitoring metrics in case of FAILURE:
save_backup_metrics_failure() {
    printf "node_mysql_backup_status{instance=\"$SERVER_NAME\"} 1\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$"
    printf "node_mysql_backup_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$"
    printf "node_mysql_backup_transfer_status{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$"
    printf "node_mysql_backup_transfer_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$"

    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom"
}


# Function to save TRANSFER monitoring metrics in case of SUCCESS: / Update Backup Age Timestamp(ms) in a separate prom. file
save_transfer_metrics_success() {
    # Add Success Transfer Stats to Node_Exporter file:
    printf "node_mysql_backup_transfer_status{instance=\"$SERVER_NAME\"} 0\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom"
    printf "node_mysql_backup_transfer_duration_seconds{instance=\"$SERVER_NAME\"} $DURATION_TRANS\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom"
    printf "node_mysql_last_successful_backup_date{instance=\"$SERVER_NAME\"} $BACKUP_TIMESTAMP\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_backup_age.prom"
}


# Function to save TRANSFER monitoring metrics in case of FAILURE:
save_transfer_metrics_failure() {
    # Add Failure Transfer Stats to Node_Exporter file:
    printf "node_mysql_backup_transfer_status{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom"
    printf "node_mysql_backup_transfer_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_backup_status.prom"
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
        --mysql_shell|--xtrabackup|--mysql_shell_local|--xtrabackup_local)
            start_log "$1"

            if [ -z "$GCP_BINARY_PATH" ] && [[ "$1" != *_local ]]; then
                echo -e "${RED}Error: gcloud CLI is not installed or not in PATH. Please install Google Cloud SDK.${RESET}"
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
            transfer_backup
            if [ $? -eq 0 ]; then
                save_transfer_metrics_success
                echo -e "${GREEN}Saved Successful Transfer Metrics for XtraBackup.${RESET}"
            else
                save_transfer_metrics_failure
                echo -e "${RED}Saved Failed Transfer Metrics for XtraBackup!${RESET}"
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


