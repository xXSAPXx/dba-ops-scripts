#!/bin/env bash

set -uo pipefail

# The script is used to backup MySQL binlog files to Google Cloud Storage: 
# The script is intended to be run as a cron job every 15-30 minutes.
# It writes binlog backup metrics in /node_exporter/textfile_collector/ to be scraped by Prometheus.


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
GCP_BINARY_PATH=$(which gcloud) || { echo -e "${RED}Error: gcloud CLI is not installed or not in PATH. Please install Google Cloud SDK.${RESET}"; }
GCS_BUCKET="gs://db-dela-gamification-dev-src-backup/binlog_backups"
SERVER_NAME=$(hostname -s)
TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector/"
LOCK_FILE="/var/lock/mysql_binlog_backup.lock"
BACKUP_TIMESTAMP=$(($(date +%s) * 1000))


# Function Help: 
show_help(){
    echo "================================================================================================================================="
    echo
    echo -e "${GREEN}Available Binlog Backup Options:${RESET} 🧊 🪧 🤌"
    echo
    echo -e "  ${CYAN}--binlog_backup${RESET}   | Backup MySQL inactive binlog files to GCP Bucket and save backup monitoring metrics."
    echo -e "  ${CYAN}--help${RESET}            | Display this help message."
    echo
    echo "================================================================================================================================="
}


# Function to initiate MySQL binlog backup:
mysql_binlog_backup(){

# Start time of the binlog backup script:
START_BINLOG_BACKUP="$(date +%s)"

# Get the list of binary log files: 
BINLOG_LIST=$(mysql --login-path=local -B -N -e "SHOW BINARY LOGS;" | awk '{print $1}') || {
    echo -e "${RED}Error: Unable to retrieve the list of binary log files from MySQL.${RESET}"; 
    return 1; }

# Flush logs to create a new binary log file and avoid copying the currently active log file:
mysql --login-path=local -e "FLUSH LOGS;" || {
    echo -e "${RED}Error: Unable to flush MySQL logs.${RESET}"; 
    return 1; }


# Check tracking file (using -s to check if it exists AND has content) and read the last backed up binary log file:
if [ -s "$LAST_BINLOG_BACKUP_FILE" ]; then
    LAST_BACKED_UP_BINLOG=$(cat "$LAST_BINLOG_BACKUP_FILE") || {
        echo -e "${RED}Error: Unable to read the last binlog backup tracking file.${RESET}"; 
        return 1; }

else
# File is missing or empty, initialize with the first binlog file:
    echo "mysql-bin.000000" > "$LAST_BINLOG_BACKUP_FILE" || {
        echo -e "${RED}Error: Unable to create binlog backup tracking file.${RESET}"; 
        return 1; }
    
    LAST_BACKED_UP_BINLOG="mysql-bin.000000" 

fi


# Number of binary log files uploaded in this run:
BINLOG_UPLOADED_COUNT=0

# Loop through the list of binary log files and copy them to GCS bucket:
for BINLOG_FILE in $BINLOG_LIST; do
    # Check if the binary log file has already been backed up by checking the local binlog tracking file:
    if [[ "$BINLOG_FILE" > "$LAST_BACKED_UP_BINLOG" ]]; then
        echo -e "${YELLOW}----Backing up binary log file: $BINLOG_FILE----${RESET}"
        
        # Copy the binary log file to GCS bucket.
        # --if-generation-match=0 makes the upload fail if an object with this name already exists, so a binlog with the
        # same name from another binlog sequence (restore, reset, rebuild) is never silently skipped or overwritten:
        $GCP_BINARY_PATH storage cp --if-generation-match=0 "$DATA_DIR/$BINLOG_FILE" "$GCS_BUCKET/$(date +%Y-%m-%d)/$BINLOG_FILE"
        BINLOG_TRANSFER_STATUS=$?

        # Check if the binary log file was copied successfully:
        if [ $BINLOG_TRANSFER_STATUS -ne 0 ]; then
            echo -e "${RED}Error backing up binary log file: $BINLOG_FILE${RESET}"
            echo -e "${RED}If gcloud reported a failed precondition, $GCS_BUCKET/$(date +%Y-%m-%d)/$BINLOG_FILE already exists. Check whether it belongs to another binlog sequence before moving or deleting it.${RESET}"
            return 1 # Failure
        fi

        # Update the last backed up binary log file tracking file:
        echo "$BINLOG_FILE" > "$LAST_BINLOG_BACKUP_FILE"
        BINLOG_FILE_UPDATE_STATUS=$?

        # Check if the tracking file was updated successfully:
        if [ $BINLOG_FILE_UPDATE_STATUS -ne 0 ]; then
            echo -e "${RED}Error updating the last binlog backup tracking file after backing up: $BINLOG_FILE${RESET}"
            return 1 # Failure
        fi

        BINLOG_UPLOADED_COUNT=$((BINLOG_UPLOADED_COUNT + 1))
    fi
done

# The FLUSH above closed the binlog that was active when the list was taken, so a healthy run always uploads at least one file.
# Zero uploads means the binlog numbering went backwards (e.g. RESET BINARY LOGS AND GTIDS or a rebuilt server):
if [ "$BINLOG_UPLOADED_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No binary log file newer than $LAST_BACKED_UP_BINLOG was found. If the binlog numbering was reset, delete $LAST_BINLOG_BACKUP_FILE so the next run starts from the new sequence.${RESET}"
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
    local LAST_BACKED_UP_BINLOG=$(cat "$LAST_BINLOG_BACKUP_FILE" | awk '{sub(/^mysql-bin\./,"",$1); print $1}')

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
        echo -e "${RED}Error: Exactly one argument is required.${RESET}"
        show_help
        exit 1
    fi 

    case "$1" in
        --binlog_backup)
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

main "${1:-}"
