#!/bin/bash

set -uo pipefail

# Main script for exporting LOGICAL and PHYSICAL production DB backups. (Version 1)
# 1) Uses Percona (MySQL Shell) or Percona (Xtrabackup) to make a full instance backup.
# 2) Transfers the backup to specific GCP Bucket.
# 3) Updates node_exporter text collector files for Grafana backup monitoring in case of SUCCESS or FAILURE.
# 4) Backups can be performed LOCALLY by both utilities if needed.


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
GCP_BINARY_PATH=$(which gcloud) || { echo -e "${RED}Error: gcloud CLI is not installed or not in PATH. Please install Google Cloud SDK.${RESET}"; }
GCP_BUCKET="gs://db-dela-gamification-stg-src-backup"
TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector/"
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
    echo "================================================================================================================================="
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



# Function for MySQL Shell Backup:
mysql_shell_backup(){

    command -v mysqlsh >/dev/null 2>&1
    if [ $? -eq 0 ]; then

        echo -e "${YELLOW}Starting MySQL Shell Backup at ${CURRENT_TIME} ${RESET}"

                # Start time of the backup script:
                START_BACKUP="$(date +%s)"

                # Perform a full instance backup with MySQL Shell: // Ensures consistency without locking!
            mysqlsh --login-path=local -S /var/lib/mysql/mysql.sock --js <<EOF
        util.dumpInstance('${BACKUP_DIR_SHELL}', {
        bytesPerChunk: '100M',
        threads: 2,
        compatibility: ['strip_invalid_grants'] })
EOF
        # Save Backup Exit Code:
        MYSQL_SHELL_EXIT_CODE=$?
        if [ $MYSQL_SHELL_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}MySQL Shell Backup Failed!${RESET}"
            return 1
        fi

        # Archive / Zip the MySQL Shell backup folder:
        time cd ${BACKUP_DIR} && tar -zcf full-instance-backup-${CURRENT_TIME}.tar.gz ${BACKUP_DIR_SHELL}

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



# Function for Xtrabackup Backup:
xtrabackup_backup() {
    if command -v xtrabackup >/dev/null 2>&1; then

        echo -e "${YELLOW}Starting XtraBackup at ${CURRENT_TIME} ${RESET}"

        # Start time of the backup script:
        START_BACKUP="$(date +%s)"

        # Go to BACKUP_DIR:
        cd ${BACKUP_DIR} || { echo -e "${RED}Error: Failed to change directory to ${BACKUP_DIR} ${RESET}"; return 1; }

        # Run Xtrabackup and check for failure
        xtrabackup --backup --datadir="${DATA_DIR}" --stream=xbstream --throttle=60 --parallel=2 --compress \
            --compress-zstd-level=1 --compress-threads=2 --no-server-version-check --login-path=local \
            > "${BACKUP_DIR}/${CURRENT_TIME}-dbfull.xbstream"

        # Save Backup Exit Code:
        XTRABACKUP_EXIT_CODE=$?
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
        echo -e "${RED}Percona Xtrabackup is not installed.${RESET}"
        return 1
    fi
}



# Function to Archive and Compress new backups / Delete old backups:
manage_old_backups() {
time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type d  -name 'full-instance-backup*' -mtime +0 -exec rm -rfv {} \;
time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type f  -name 'full-instance-backup*gz' -mtime +2 -exec rm -rfv {} \;
time find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type f  -name '*.xbstream' -mmin +1380 -exec rm -fv {} \;
echo -e "${GREEN}Old Backups Cleaned Up.${RESET}"
}



# Function to Transfer MySQL_Shell or XBackup to GCP Bucket:
transfer_backup(){
# Start time of the GCP Bucket transfer
START_TRANS="$(date +%s)"

############## INITIATE MYSQL_SHELL BACKUP TRANSFER ##############
if [ -d "$BACKUP_DIR_SHELL" ]; then
    echo -e "${YELLOW}Initiating GCP Bucket Transfer For MySQL Shell Backup.${RESET}"

    # Upload New Backup to GCP Bucket:
    ${GCP_BINARY_PATH} storage cp \
    ${BACKUP_DIR}/full-instance-backup-${CURRENT_TIME}.tar.gz \
    ${GCP_BUCKET}/full-instance-backup-${CURRENT_TIME}.tar.gz

    # Check Transfer Code:
    TRANSFER_EXIT_CODE=$?
    if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Transfer to GCP Bucket Failed! (MySQL Shell)${RESET}"
        return 1
    else
        echo -e "${GREEN}Successfully Transfered Backup to GCP Bucket.${RESET}"
    fi

    # End Time of the Transfer.
    END_TRANS="$(date +%s)"

    # Calculate Backup Duration:
    DURATION_TRANS="$(( ($END_TRANS - $START_TRANS) + 2 ))"
    echo "Duration in Seconds: $(($END_TRANS - $START_TRANS))"



#################### INITIATE XTRABACKUP TRANSFER ####################
elif [ -f "${BACKUP_DIR}/${CURRENT_TIME}-dbfull.xbstream" ]; then

    echo -e "${YELLOW}Initiating GCP Bucket Transfer For Xtrabackup.${RESET}"

    # Upload New Backup to GCP Bucket:
    ${GCP_BINARY_PATH} storage cp \
    ${BACKUP_DIR}/${CURRENT_TIME}-dbfull.xbstream  \
    ${GCP_BUCKET}/${CURRENT_TIME}-dbfull.xbstream


    # Check Transfer Code:
    TRANSFER_EXIT_CODE=$?
    if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Transfer to GCP Bucket Failed! (XtraBackup)${RESET}"
        return 1
    else
        echo -e "${GREEN}Successfully Transfered Backup to GCP Bucket.${RESET}"
    fi

    # End Time of the Transfer.
    END_TRANS="$(date +%s)"

    # Calculate Backup Duration:
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
    if [ -z "$1" ]; then
        echo
        echo -e "${RED}Error: Exactly one argument is required.${RESET}"
        show_help
        exit 1
    fi

    check_host

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

main "${1:-}"


