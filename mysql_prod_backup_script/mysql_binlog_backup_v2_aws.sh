#!/bin/env bash

set -uo pipefail

# The AWS version of mysql_binlog_backup_v2.sh: the same logic, with the upload to Amazon S3 instead of Google Cloud Storage.
# The AWS CLI takes its credentials from the server's IAM role.
# The script is used to backup MySQL binlog files to Amazon S3:
# A person starts a binlog chain once with --init_binlog_chain, then cron runs --continuous_binlog_backup every 15-30 minutes.
# It writes binlog backup metrics in /node_exporter/textfile_collector/ to be scraped by Prometheus.
# It logs every run (normal execution and errors, with colors) to /var/log/mysql_binlog_backup.log. Rotation: mysql_binlog_backup.logrotate.example.


# =================================================================================================================================
# Maybe add a active binlog metric / last backed up binlog metric to the node exporter textfile_collector.
# =================================================================================================================================


# Colors for output:
WHITE="\e[1m"
GREEN="\e[32m"
CYAN="\e[36m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

DATA_DIR="/var/lib/mysql"
LAST_BINLOG_BACKUP_FILE="/opt/last_binlog_backup.txt"
AWS_BINARY_PATH=$(which aws) || { echo -e "${RED}Error: AWS CLI is not installed or not in PATH. Please install the AWS CLI v2.${RESET}"; }
# Set the S3 bucket and folder of this server before the first run (in the aws-dba-labs lab: terraform output backup_s3_prefix,
# then binlog_backups). Binlogs go to <bucket>/<folder>/<server name>/<date>/:
S3_BUCKET="s3://BUCKET/mysql/binlog_backups"
SERVER_NAME=$(hostname -s)
TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector/"
LOCK_FILE="/var/lock/mysql_binlog_backup.lock"
LOG_FILE="/var/log/mysql_binlog_backup.log"
# An upload of one binary log that takes longer is stopped, and the next run retries it. Keep it well above the slowest normal upload (max_binlog_size):
UPLOAD_TIMEOUT="30m"
BACKUP_TIMESTAMP=$(($(date +%s) * 1000))


# Function Help: 
show_help(){
    echo "================================================================================================================================="
    echo
    echo -e "${GREEN}Available Binlog Backup Options:${RESET} 🧊 🪧 🤌"
    echo
    printf "  ${CYAN}%-32s${RESET}  | %s\n" \
        "--init_binlog_chain <binary log>" "Start a new binlog chain with <binary log>, e.g. --init_binlog_chain mysql-bin.000150" \
        "" "Run it once, by hand, before the first --continuous_binlog_backup run on a server." \
        "" "It uploads nothing itself: the next --continuous_binlog_backup run uploads <binary log> and every binary log after it." \
        "" "It refuses to run while a chain exists ($LAST_BINLOG_BACKUP_FILE): to start over, delete that file first." \
        "" "" \
        "--continuous_binlog_backup" "Upload the closed binary logs of the chain to the S3 bucket and save backup monitoring metrics." \
        "" "Run it from cron every 15-30 minutes. It fails until a chain is started with --init_binlog_chain," \
        "" "and it stops with an error when a binary log is missing from the chain (a gap)." \
        "" "" \
        "--help" "Display this help message."
    echo
    echo -e "  Every --init_binlog_chain and --continuous_binlog_backup run is logged to $LOG_FILE (with colors: less -R $LOG_FILE)."
    echo
    echo -e "${GREEN}Which binary log to start the chain from (--init_binlog_chain):${RESET}"
    echo
    printf "  ${CYAN}%-53s${RESET} | ${CYAN}%s${RESET}\n" "Situation" "Start from"
    printf "  %-53s | %s\n" \
        "New server, or one that never had binlog backups" "The oldest binary log on the server: the first row of SHOW BINARY LOGS." \
        "" "" \
        "Server that already has binlog backups" "The binary log after the last one in the bucket. To find the last one:" \
        "(script reinstalled, tracking file lost)" "  aws s3 ls --recursive \"$S3_BUCKET/$SERVER_NAME/\" | awk -F/ '{print \$NF}' | sort | tail -n 1" \
        "" "" \
        "After a gap in the chain" "Take a new full backup, then start from the binary log that backup starts from:" \
        "(binary logs purged before they were uploaded)" "  xtrabackup_binlog_info in the backup, or binlogFile in the @.json file of a MySQL Shell dump." \
        "" "" \
        "After a numbering reset, a rebuilt server or failover" "Take a new full backup, then start from the oldest binary log on this server:" \
        "(RESET BINARY LOGS AND GTIDS, restore from backup)" "  the first row of SHOW BINARY LOGS."
    echo
    echo "================================================================================================================================="
}


# Function to copy everything this run prints (normal execution and errors, with their colors) to the log file as well as to the screen.
# Read the log with its colors: less -R on the log file.
start_log(){
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo
    echo -e "${CYAN}===== $(date '+%Y-%m-%d %H:%M:%S') | $SERVER_NAME | $1 =====${RESET}"
}


# Function to write the tracking file: a temporary file renamed over it, so a full disk or a crash never leaves it empty or half written:
write_tracking_file(){
    { echo "$1" > "$LAST_BINLOG_BACKUP_FILE.tmp" && mv "$LAST_BINLOG_BACKUP_FILE.tmp" "$LAST_BINLOG_BACKUP_FILE"; } || {
        echo -e "${RED}Error: Unable to write the tracking file $LAST_BINLOG_BACKUP_FILE.${RESET}"
        rm -f "$LAST_BINLOG_BACKUP_FILE.tmp"
        return 1; }
}


# Function to start a new binlog chain (run once, by hand). The chain starts with the given binary log:
init_binlog_chain(){
    local START_BINLOG="$1"

    if [[ ! "$START_BINLOG" =~ ^mysql-bin\.[0-9]+$ ]]; then
        echo -e "${RED}Error: --init_binlog_chain needs the binary log the chain starts with, e.g. --init_binlog_chain mysql-bin.000150 (got: '$START_BINLOG').${RESET}"
        echo -e "${YELLOW}Run --help to see which binary log to start from.${RESET}"
        return 1
    fi

    # A tracking file means a chain is already running. Starting over it could skip binary logs without any error, so a person deletes it on purpose first:
    if [ -e "$LAST_BINLOG_BACKUP_FILE" ]; then
        echo -e "${RED}Error: A binlog chain already exists: $LAST_BINLOG_BACKUP_FILE (last backed up: $(cat "$LAST_BINLOG_BACKUP_FILE" 2>/dev/null)).${RESET}"
        echo -e "${RED}To start a new chain, delete $LAST_BINLOG_BACKUP_FILE first, then run --init_binlog_chain again.${RESET}"
        return 1
    fi

    # The chain can only start with a binary log that is still on the server:
    local BINLOG_LIST
    BINLOG_LIST=$(mysql --login-path=local -B -N -e "SHOW BINARY LOGS;" | awk '{print $1}') || {
        echo -e "${RED}Error: Unable to retrieve the list of binary log files from MySQL.${RESET}"
        return 1; }

    if ! grep -qxF "$START_BINLOG" <<< "$BINLOG_LIST"; then
        echo -e "${RED}Error: $START_BINLOG is not on the server. The binary logs on the server are $(head -n 1 <<< "$BINLOG_LIST") to $(tail -n 1 <<< "$BINLOG_LIST").${RESET}"
        echo -e "${RED}If it was purged before it was uploaded, the chain has a gap: take a new full backup and start from the binary log that backup starts from (see --help).${RESET}"
        return 1
    fi

    # The tracking file holds the last backed up binary log, so it gets the one before the start:
    write_tracking_file "$(printf 'mysql-bin.%06d' $((10#${START_BINLOG##*.} - 1)))" || return 1

    echo -e "${GREEN}New binlog chain started with $START_BINLOG. The next --continuous_binlog_backup run uploads it and every binary log after it.${RESET}"
}


# Function to initiate MySQL binlog backup:
mysql_binlog_backup(){

# Start time of the binlog backup script:
START_BINLOG_BACKUP="$(date +%s)"

# The tracking file holds the last backed up binary log. Without it there is no chain to continue: a person starts one with --init_binlog_chain.
# It is read first, so a server without a chain fails here without rotating its binary log:
if [ ! -e "$LAST_BINLOG_BACKUP_FILE" ]; then
    echo -e "${RED}Error: No binlog chain to continue: $LAST_BINLOG_BACKUP_FILE does not exist. Start one with --init_binlog_chain <binary log> (--help shows which binary log to start from).${RESET}"
    return 1
fi

LAST_BACKED_UP_BINLOG=$(cat "$LAST_BINLOG_BACKUP_FILE") || {
    echo -e "${RED}Error: Unable to read the last binlog backup tracking file.${RESET}"
    return 1; }

# The tracking file must hold a binary log file name such as mysql-bin.000123 (the number is needed for the gap check):
if [[ ! "$LAST_BACKED_UP_BINLOG" =~ \.[0-9]+$ ]]; then
    echo -e "${RED}Error: The tracking file $LAST_BINLOG_BACKUP_FILE does not hold a binary log file name: '$LAST_BACKED_UP_BINLOG'.${RESET}"
    echo -e "${RED}Find the last binary log in the bucket, delete $LAST_BINLOG_BACKUP_FILE and run --init_binlog_chain with the binary log after it (see --help).${RESET}"
    return 1
fi

# 10# reads the number as decimal (a leading zero would make bash read 000008 as an invalid octal number):
LAST_BACKED_UP_NUMBER=$((10#${LAST_BACKED_UP_BINLOG##*.}))

# Get the list of binary log files: 
BINLOG_LIST=$(mysql --login-path=local -B -N -e "SHOW BINARY LOGS;" | awk '{print $1}') || {
    echo -e "${RED}Error: Unable to retrieve the list of binary log files from MySQL.${RESET}"; 
    return 1; }

# Flush the binary log to create a new binary log file and avoid copying the currently active log file.
# FLUSH BINARY LOGS rotates only the binary log (FLUSH LOGS also reopens the error, slow and general logs and rotates the relay logs of a replica):
mysql --login-path=local -e "FLUSH BINARY LOGS;" || {
    echo -e "${RED}Error: Unable to flush the MySQL binary logs.${RESET}";
    return 1; }


# Number of binary log files uploaded in this run:
BINLOG_UPLOADED_COUNT=0

# Loop through the list of binary log files and copy them to the S3 bucket:
for BINLOG_FILE in $BINLOG_LIST; do
    # Check if the binary log file has already been backed up by checking the local binlog tracking file:
    if [[ "$BINLOG_FILE" > "$LAST_BACKED_UP_BINLOG" ]]; then
        BINLOG_NUMBER=$((10#${BINLOG_FILE##*.}))

        # MySQL purges binary logs after binlog_expire_logs_seconds whether they were uploaded or not.
        # A binary log missing from the sequence is a gap that point-in-time recovery cannot cross, so stop here and fail on every run until it is handled:
        if [ "$BINLOG_NUMBER" -ne $((LAST_BACKED_UP_NUMBER + 1)) ]; then
            EXPECTED_BINLOG=$(printf '%s.%06d' "${BINLOG_FILE%.*}" $((LAST_BACKED_UP_NUMBER + 1)))
            echo -e "${RED}Error: Gap in the binlog chain after $LAST_BACKED_UP_BINLOG: the next binary log on the server is $BINLOG_FILE, not $EXPECTED_BINLOG. The binary logs in between were purged before they were uploaded.${RESET}"
            echo -e "${RED}Point-in-time recovery cannot go past the end of $LAST_BACKED_UP_BINLOG and the old chain cannot be repaired. Take a new full backup now, then delete $LAST_BINLOG_BACKUP_FILE and run --init_binlog_chain with the binary log that backup starts from (see --help).${RESET}"
            return 1 # Failure
        fi

        echo -e "${YELLOW}----Backing up binary log file: $BINLOG_FILE----${RESET}"
        
        # Copy the binary log file to the S3 bucket.
        # --if-none-match '*' makes the upload fail if an object with this name already exists, so a binlog with the
        # same name from another binlog sequence (restore, reset, rebuild) is never silently skipped or overwritten.
        # aws s3 cp has no such option, so s3api put-object does the upload: one request, up to 5 GB (max_binlog_size is at most 1 GB).
        # One folder per server, so the binary logs of different servers (failover, rebuilt server, cloned VM) never mix:
        BINLOG_DESTINATION="$S3_BUCKET/$SERVER_NAME/$(date +%Y-%m-%d)/$BINLOG_FILE"
        # put-object takes the bucket and the key separately: s3://<bucket>/<key>
        BINLOG_DESTINATION_PATH="${BINLOG_DESTINATION#s3://}"
        # timeout stops an upload that hangs (network stall, stuck login), so this run fails and the next one retries, instead of the hung
        # run holding the lock and every later run skipping. --kill-after kills aws if it ignores the stop signal.
        # 9>&- keeps the lock out of aws and its worker processes: uutils timeout (Ubuntu 25.10+) kills only aws itself, and a
        # surviving worker that still held the lock would make every later run skip:
        timeout --kill-after=1m "$UPLOAD_TIMEOUT" $AWS_BINARY_PATH s3api put-object --if-none-match '*' \
            --bucket "${BINLOG_DESTINATION_PATH%%/*}" --key "${BINLOG_DESTINATION_PATH#*/}" --body "$DATA_DIR/$BINLOG_FILE" 9>&-
        BINLOG_TRANSFER_STATUS=$?

        # Check if the binary log file was copied successfully:
        if [ $BINLOG_TRANSFER_STATUS -ne 0 ]; then
            echo -e "${RED}Error backing up binary log file: $BINLOG_FILE${RESET}"

            # timeout exits with 124 when it stopped the upload, and with 137 when it had to kill it:
            if [ $BINLOG_TRANSFER_STATUS -eq 124 ] || [ $BINLOG_TRANSFER_STATUS -eq 137 ]; then
                echo -e "${RED}The upload did not finish within $UPLOAD_TIMEOUT and was stopped. The next run retries it.${RESET}"
            else
                echo -e "${RED}If AWS reported PreconditionFailed, $BINLOG_DESTINATION already exists. Check whether it belongs to another binlog sequence before moving or deleting it.${RESET}"
            fi
            return 1 # Failure
        fi

        # Update the last backed up binary log file tracking file:
        write_tracking_file "$BINLOG_FILE"
        BINLOG_FILE_UPDATE_STATUS=$?

        # Check if the tracking file was updated successfully:
        if [ $BINLOG_FILE_UPDATE_STATUS -ne 0 ]; then
            echo -e "${RED}Error updating the last binlog backup tracking file after backing up: $BINLOG_FILE${RESET}"
            return 1 # Failure
        fi

        # The next binary log of this run must follow this one:
        LAST_BACKED_UP_BINLOG="$BINLOG_FILE"
        LAST_BACKED_UP_NUMBER=$BINLOG_NUMBER

        BINLOG_UPLOADED_COUNT=$((BINLOG_UPLOADED_COUNT + 1))
    fi
done

# The FLUSH above closed the binlog that was active when the list was taken, so a healthy run always uploads at least one file.
# Zero uploads means the binlog numbering went backwards (e.g. RESET BINARY LOGS AND GTIDS or a rebuilt server):
if [ "$BINLOG_UPLOADED_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No binary log file newer than $LAST_BACKED_UP_BINLOG was found: the binlog numbering went backwards (RESET BINARY LOGS AND GTIDS, a rebuilt server).${RESET}"
    echo -e "${RED}Take a new full backup, then delete $LAST_BINLOG_BACKUP_FILE and run --init_binlog_chain with the oldest binary log on this server (see --help).${RESET}"
    return 1 # Failure
fi

# End time of the binlog backup script:
END_BINLOG_BACKUP="$(date +%s)"

# Calculate backup duration: 
		DURATION_BINLOG_BACKUP="$(( ($END_BINLOG_BACKUP - $START_BINLOG_BACKUP) + 2 ))"
        echo 
		echo -e "${YELLOW}Duration in Seconds:${RESET} $(($END_BINLOG_BACKUP - $START_BINLOG_BACKUP))"
        return 0  # Success
}


# Function to save BINLOG_BACKUP monitoring metrics in case of SUCCESS:
save_binlog_backup_metrics_success() {

    # The active binary log is the last one listed (SHOW MASTER STATUS was removed in MySQL 8.4):
    local ACTIVE_BINLOG=$(mysql --login-path=local -B -N -e "SHOW BINARY LOGS;" | tail -n 1 | awk '{sub(/^mysql-bin\./,"",$1); print $1}')
    local LAST_BACKED_UP_BINLOG=$(cat "$LAST_BINLOG_BACKUP_FILE" | awk '{sub(/^mysql-bin\./,"",$1); print $1}')

    # Add Success Binlog_Backup Stats to Node_Exporter file: 
    printf "node_mysql_binlog_backup_status{instance=\"$SERVER_NAME\"} 0\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"
    printf "node_mysql_binlog_backup_duration_seconds{instance=\"$SERVER_NAME\"} $DURATION_BINLOG_BACKUP\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"

    # A metric with an empty or non-numeric value makes node_exporter drop the whole file, so skip values that could not be read:
    if [[ "$ACTIVE_BINLOG" =~ ^[0-9]+$ ]]; then
        printf "node_mysql_current_active_binlog{instance=\"$SERVER_NAME\"} $ACTIVE_BINLOG\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"
    else
        echo -e "${YELLOW}Warning: Unable to read the active binary log file, skipping node_mysql_current_active_binlog metric.${RESET}"
    fi

    if [[ "$LAST_BACKED_UP_BINLOG" =~ ^[0-9]+$ ]]; then
        printf "node_mysql_last_backed_up_binlog{instance=\"$SERVER_NAME\"} $LAST_BACKED_UP_BINLOG\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"
    else
        echo -e "${YELLOW}Warning: Unable to read the last backed up binary log file, skipping node_mysql_last_backed_up_binlog metric.${RESET}"
    fi

    printf "node_mysql_last_successful_binlog_backup_date{instance=\"$SERVER_NAME\"} $BACKUP_TIMESTAMP\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_age.prom"
    
    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom"
}


# Function to save BINLOG_BACKUP monitoring metrics in case of FAILURE:
save_binlog_backup_metrics_failure() {

    # The active binary log is the last one listed (SHOW MASTER STATUS was removed in MySQL 8.4):
    local ACTIVE_BINLOG=$(mysql --login-path=local -B -N -e "SHOW BINARY LOGS;" | tail -n 1 | awk '{sub(/^mysql-bin\./,"",$1); print $1}')
    local LAST_BACKED_UP_BINLOG=$(cat "$LAST_BINLOG_BACKUP_FILE" 2>/dev/null | awk '{sub(/^mysql-bin\./,"",$1); print $1}')

    printf "node_mysql_binlog_backup_status{instance=\"$SERVER_NAME\"} 1\n" > "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"
    printf "node_mysql_binlog_backup_duration_seconds{instance=\"$SERVER_NAME\"} 1\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"

    # A metric with an empty or non-numeric value makes node_exporter drop the whole file, so skip values that could not be read:
    if [[ "$ACTIVE_BINLOG" =~ ^[0-9]+$ ]]; then
        printf "node_mysql_current_active_binlog{instance=\"$SERVER_NAME\"} $ACTIVE_BINLOG\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"
    else
        echo -e "${YELLOW}Warning: Unable to read the active binary log file, skipping node_mysql_current_active_binlog metric.${RESET}"
    fi

    if [[ "$LAST_BACKED_UP_BINLOG" =~ ^[0-9]+$ ]]; then
        printf "node_mysql_last_backed_up_binlog{instance=\"$SERVER_NAME\"} $LAST_BACKED_UP_BINLOG\n" >> "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$"
    else
        echo -e "${YELLOW}Warning: Unable to read the last backed up binary log file, skipping node_mysql_last_backed_up_binlog metric.${RESET}"
    fi

    # Rename the temporary file atomically.
    # This avoids the node exporter seeing half a file.
    mv "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom.$$" \
       "$TEXTFILE_COLLECTOR_DIR/mysql_binlog_backup_status.prom"
}



########################### Main script logic: ###########################
main() {
    if [ -z "$1" ]; then
        echo
        echo -e "${RED}Error: An option is required.${RESET}"
        show_help
        exit 1
    fi 

    case "$1" in
        --init_binlog_chain)
            start_log "--init_binlog_chain $2"
            init_binlog_chain "$2" || exit 1
            ;;

        --continuous_binlog_backup)
            start_log "--continuous_binlog_backup"

            # Only one backup may run at a time. The lock is released automatically when the script exits:
            exec 9> "$LOCK_FILE" || {
                echo -e "${RED}Error: Unable to open the lock file $LOCK_FILE.${RESET}"
                save_binlog_backup_metrics_failure
                exit 1; }

            # A previous run still holding the lock is not a failure. Metrics are left untouched, so a run that hangs
            # shows up as a stale node_mysql_last_successful_binlog_backup_date:
            if ! flock -n 9; then
                echo -e "${YELLOW}Another binlog backup is still running, skipping this run.${RESET}"
                exit 0
            fi

            mysql_binlog_backup
            if [ $? -eq 0 ]; then
                save_binlog_backup_metrics_success
                echo -e "${GREEN}Saved Success Metrics for MySQL Binlog Backup.${RESET}"
            else
                save_binlog_backup_metrics_failure
                echo -e "${RED}Saved Failure Metrics for MySQL Binlog Backup!${RESET}" 
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

main "${1:-}" "${2:-}"
