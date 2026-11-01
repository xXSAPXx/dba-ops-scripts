#!/bin/env bash

current_time=$(date '+%Y-%m-%d %H:%M:%S')

echo -e "\nStart time: $current_time\n"

for file in `find /var/lib/mysql/ -type f -name "mysql-bin.[0-9]*" -mmin +1 -mmin -60 -exec ls -1 {} \;` ; do gsutil cp -n $file  gs://delasport-mysql-backup/binlogs_backup/$(date +%Y-%m-%d)/ ; done

echo -e "\nEnd time: $current_time"
