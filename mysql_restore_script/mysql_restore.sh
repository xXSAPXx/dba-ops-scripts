#!/bin/bash
set -euo pipefail

# === Colors ===
GREEN="\e[32m"
CYAN="\e[36m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

# === Log file ===
LOG_FILE="/opt/restore_script.log"

# === Backup argument check ===
BACKUP_PATH="${1:-}"

if [ -z "$BACKUP_PATH" ]; then
    echo
    echo -e "${RED}╰┈➤ Error: Missing Xtrabackup file argument.${RESET}"
    echo "======================================================================================================================"
    echo
    echo -e " ${CYAN}--Example Usage:${RESET}       | $0 gs://delasport-mysql-backup/2025-11-02-230001-dbfull.xbstream"
    echo
    echo -e " ${CYAN}--Check Latest Backup:${RESET} | gcloud storage ls -l gs://delasport-mysql-backup/"
    echo
    echo "======================================================================================================================"
    exit 1
fi

echo
echo "======================================================================================================================"
echo
echo -e "${GREEN} Starting MySQL restore using Xtrabackup:${RESET} $BACKUP_PATH"
echo
echo -e "${CYAN} All output is being logged to:${RESET} $LOG_FILE"
echo
echo "======================================================================================================================"
echo

exec > >(tee "$LOG_FILE") 2>&1

START_TIME="$(date +%s)"
echo -e "${GREEN}Restore started at: $(date) ${RESET}"
echo
echo -e  "${YELLOW}Stopping mysqld...${RESET}"
systemctl stop mysqld
echo -e  "${YELLOW}Stopped mysqld.${RESET}"
echo
echo -e "${YELLOW}Cleaning /var/lib/mysql...${RESET}"
rm -rf /var/lib/mysql/*
mkdir -p /var/lib/mysql/
chown -R mysql:mysql /var/lib/mysql
echo -e "${YELLOW}Directory prepared at: $(date) ${RESET}"
echo
echo -e "${YELLOW}Starting restore from backup...${RESET}"
gsutil cat "$BACKUP_PATH" | xbstream -x -C /var/lib/mysql --parallel=16 --decompress --decompress-threads=16 --verbose
echo -e "${YELLOW}Restore finished at: $(date) ${RESET}"
echo
echo -e "${YELLOW}Preparing backup...${RESET}"
# Too much --use-memory can OOM the server: xtrabackup can't use huge pages reserved for MySQL (vm.nr_hugepages).
# Check with MySQL stopped: grep -E 'HugePages_Total|Hugepagesize|MemAvailable' /proc/meminfo. Then use about half of MemAvailable:
xtrabackup --prepare --use-memory=64GB --target-dir=/var/lib/mysql
echo -e "${YELLOW}Backup prepared at: $(date) ${RESET}"
echo
echo -e "${YELLOW}Creating relaylog, doublebuff, binlog, log directories...${RESET}"
cd /var/lib/mysql && mkdir relaylog doublebuff binlog log
chown -R mysql:mysql /var/lib/mysql
echo
echo -e "${YELLOW}Starting mysqld...${RESET}"
systemctl start mysqld
echo -e "${YELLOW}Started mysqld.${RESET}"
echo
END_TIME=$(date +%s)
RESTORE_DURATION=$((END_TIME - START_TIME))
# Convert seconds to hours/minutes/seconds
HOURS=$((RESTORE_DURATION / 3600))
MINUTES=$(((RESTORE_DURATION % 3600) / 60))
SECONDS=$((RESTORE_DURATION % 60))
echo -e "${GREEN}Restore Completed - ⏳ Total restore duration: ${HOURS}h ${MINUTES}m ${SECONDS}s ${RESET}"
