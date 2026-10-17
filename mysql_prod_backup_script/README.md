# MySQL binlog backup

`mysql_binlog_backup_v2.sh` copies the closed MySQL binary logs of a server to a Google Cloud Storage bucket, so a full backup plus the binlogs after it can restore the server to any point in time. A person starts a *binlog chain* once; cron then uploads every new binlog every 15 minutes. Every run is logged, and its result is exported to node_exporter for Prometheus and Grafana.

The full backups (`mysql_backup_v2.sh`, XtraBackup or MySQL Shell) are separate; a restore needs both.

| File | What it is |
|---|---|
| `mysql_binlog_backup_v2.sh` | The script |
| `mysql_binlog_backup.logrotate.example` | Log rotation for `/var/log/mysql_binlog_backup.log` |
| `tests/test_mysql_binlog_backup.sh` | Tests against a mocked MySQL and gcloud |
| `mysql_binlog_backup_v1.sh` | The old version, kept for reference |

Diagrams of the workflow and a proposed Grafana dashboard: [Binlog Backup Workflow](https://claude.ai/artifact/5CDr7pRCdo1znVkNZuVtk2) and [Binlog Backup Dashboard](https://claude.ai/artifact/HAr99wiqaCM8e5o85q6QUu). Both are claude.ai pages; ask the repository owner to share them.


## Before the first run on a server

1. **Set the bucket.** Edit `GCS_BUCKET` at the top of the script. The value in the repository is the dev bucket. Binlogs go to `<bucket>/<server>/<date>/`.
2. **Check the MySQL login.** The script uses `mysql --login-path=local`. That user needs `REPLICATION CLIENT` (for `SHOW BINARY LOGS`) and `RELOAD` (for `FLUSH BINARY LOGS`).
3. **Check gcloud.** The VM's service account needs `roles/storage.objectCreator` on the bucket, plus `roles/storage.objectViewer` to list it. It never needs delete: old binlogs should be removed by a lifecycle rule on the bucket.
4. **Install the log rotation:** `sudo cp mysql_binlog_backup.logrotate.example /etc/logrotate.d/mysql_binlog_backup`
5. **Add the cron job**, for example in `/etc/cron.d/mysql_binlog_backup`. The script logs itself, so cron's copy of the output goes to `/dev/null`:
   ```
   */15 * * * * root /opt/scripts/mysql_binlog_backup_v2.sh --continuous_binlog_backup > /dev/null 2>&1
   ```
6. **Start the chain once**, by hand: `--init_binlog_chain <binary log>`. Until then every cron run fails and the failure alert fires.


## Commands

| Command | What it does |
|---|---|
| `--init_binlog_chain mysql-bin.000150` | Starts a chain with that binlog. It checks that the name is valid, that no chain exists and that the binlog is still on the server, then writes the binlog before it (`mysql-bin.000149`) to the tracking file. It uploads nothing and writes no metrics. |
| `--continuous_binlog_backup` | Uploads every closed binlog of the chain that is not in the bucket yet, then writes the metrics. Run by cron. It never starts a chain by itself. |
| `--help` | Shows both commands and the table below. |

### Which binlog to start a chain from

| Situation | Start from |
|---|---|
| New server, or one that never had binlog backups | The oldest binlog on the server: the first row of `SHOW BINARY LOGS` |
| Server that already has binlog backups (script reinstalled, tracking file lost) | The binlog after the last one in the bucket: `gcloud storage ls "<bucket>/<server>/**" \| awk -F/ '{print $NF}' \| sort \| tail -n 1` |
| After a gap in the chain (binlogs purged before they were uploaded) | Take a new full backup, then start from the binlog that backup starts from: `xtrabackup_binlog_info`, or `binlogFile` in the `@.json` of a MySQL Shell dump |
| After a numbering reset, a rebuilt server or a failover | Take a new full backup, then start from the oldest binlog on this server |

To start a new chain, delete the tracking file first; `--init_binlog_chain` refuses while one exists.


## How a run works

1. Start the log and take the lock. If the previous run still holds the lock, this run skips with exit 0 and leaves the metrics alone.
2. Read the last uploaded binlog from the tracking file. No file means no chain: the run fails without touching MySQL.
3. `SHOW BINARY LOGS`, then `FLUSH BINARY LOGS`. The list is taken first, so the binlog that was active is closed by the flush and uploaded in the same run. A healthy run therefore always uploads at least one binlog.
4. For each binlog newer than the tracking file, oldest first:
   - it must be the last uploaded number + 1, otherwise the binlogs in between were purged and the run stops with a **gap** error;
   - upload it to `<bucket>/<server>/<date>/` with `--if-generation-match=0` (an existing object is never overwritten), with a 30-minute limit (`UPLOAD_TIMEOUT`);
   - record it in the tracking file (written to a temporary file, then renamed, so it is never left empty).
5. Write success or failure metrics. Any failure exits 1 and the log says why.

The off-site copy is at most one cron interval plus the upload time behind the server.

| What | Where |
|---|---|
| Tracking file (last uploaded binlog) | `/opt/last_binlog_backup.txt` |
| Lock | `/var/lock/mysql_binlog_backup.lock` (the upload does not inherit it) |
| Log, with colors (`less -R`) | `/var/log/mysql_binlog_backup.log` |
| Metrics | `/var/lib/node_exporter/textfile_collector/mysql_binlog_backup_status.prom` and `mysql_binlog_backup_age.prom` |

**Load on the database:** `SHOW BINARY LOGS` twice and `FLUSH BINARY LOGS` once per run. The flush is the same rotation MySQL does itself when a binlog reaches `max_binlog_size`; commits pause for milliseconds. It takes longer only while a very large transaction is being written, or when it purges many expired binlogs at once. The upload reads the binlog files and uses some CPU and network; prefix `gcloud` with `nice -n 19 ionice -c3` if that matters.


## Failures and what the log shows

Every run starts with `===== <date> | <server> | <option> =====`. A failed run ends with `Saved Failure Metrics for MySQL Binlog Backup!`; a run with no closing line was killed (reboot, out of memory). MySQL and gcloud print their own error line before the script's.

| Failure | The script's line in the log | What to do |
|---|---|---|
| No chain started | `Error: No binlog chain to continue: /opt/last_binlog_backup.txt does not exist.` | `--init_binlog_chain` |
| Tracking file empty or damaged | `Error: The tracking file ... does not hold a binary log file name` | Find the last binlog in the bucket, delete the file, init with the next one |
| Lock file cannot be opened | `Error: Unable to open the lock file ...` | Run the script as root |
| Previous run still running | `Another binlog backup is still running, skipping this run.` (exit 0) | Nothing, unless it repeats: then a run is stuck |
| MySQL down, wrong login, binlog off | `Error: Unable to retrieve the list of binary log files from MySQL.` | Read the MySQL `ERROR` line above it |
| `FLUSH BINARY LOGS` refused | `Error: Unable to flush the MySQL binary logs.` | Grant `RELOAD` |
| Gap in the chain | `Error: Gap in the binlog chain after mysql-bin.N ...` | New full backup, delete the tracking file, init (see the table above) |
| Numbering went backwards | `Error: No binary log file newer than ... the binlog numbering went backwards` | New full backup, delete the tracking file, init with the oldest binlog |
| Upload refused (403, 404, network) | `Error backing up binary log file: mysql-bin.N` | Read the gcloud `ERROR` line above it; the next run retries |
| Object already in the bucket (412) | Same, after `HTTPError 412` | Compare the object with the local file. If it is the same file, write its name into the tracking file |
| Upload hung | `The upload did not finish within 30m and was stopped. The next run retries it.` | Check the network to Google Cloud |
| Tracking file cannot be written | `Error: Unable to write the tracking file ...` | Fix disk space or permissions; the next run hits "already exists" for that binlog (see 412) |


## Monitoring

### Metrics the script writes

| Metric | Value |
|---|---|
| `node_mysql_binlog_backup_status` | `0` success, `1` failure. Not written when a run is skipped |
| `node_mysql_binlog_backup_duration_seconds` | Run time (+2 s); `1` as a placeholder on failure |
| `node_mysql_current_active_binlog` | Number of the active binlog |
| `node_mysql_last_backed_up_binlog` | Number of the last uploaded binlog |
| `node_mysql_last_successful_binlog_backup_date` | Time of the last successful run, in **milliseconds** |

node_exporter adds `node_textfile_scrape_error` (a `.prom` file could not be read) and `node_textfile_mtime_seconds{file=...}` (when each file was last written).

A stopped script leaves its last values in place, so `status` can stay `0` forever. Always look at an age next to it.

### Proposed dashboard

Twelve panels, mocked up with example data in [Binlog Backup Dashboard](https://claude.ai/artifact/HAr99wiqaCM8e5o85q6QUu):

- **Right now:** off-site copy age, last run, binlogs waiting, last uploaded binlog, last run attempt, full backup age.
- **Last 12 hours:** off-site copy age, active vs last uploaded binlog, run result per server, run duration of successful runs, binlogs uploaded per hour.
- **All servers:** one table row per server.

### Proposed alert rules

Not yet loaded into Prometheus. Every failed run alerts on purpose: for now each failure should be looked at.

```yaml
groups:
  - name: mysql-binlog-backup
    rules:
      - alert: MySQLBinlogBackupFailed
        expr: node_mysql_binlog_backup_status == 1
        labels: { severity: warning }
        annotations: { summary: "Binlog backup failed: read /var/log/mysql_binlog_backup.log on the server" }
      - alert: MySQLBinlogOffsiteCopyTooOld
        expr: time() - node_mysql_last_successful_binlog_backup_date / 1000 > 2700
        labels: { severity: critical }
      - alert: MySQLBinlogBackupNotRunning
        expr: time() - node_textfile_mtime_seconds{file=~".*mysql_binlog_backup_status.prom"} > 2700
        labels: { severity: critical }
      - alert: MySQLBinlogsPilingUp
        expr: node_mysql_current_active_binlog - node_mysql_last_backed_up_binlog - 1 >= 3
        labels: { severity: warning }
      - alert: NodeTextfileScrapeError
        expr: node_textfile_scrape_error == 1
        for: 5m
        labels: { severity: warning }
      - alert: MySQLFullBackupTooOld
        expr: time() - node_mysql_last_successful_backup_date / 1000 > 93600
        labels: { severity: warning }
```

**Two server labels.** The scripts write their own `instance` label, which Prometheus usually renames to `exported_instance`. node_exporter's own metrics (`node_textfile_*`) only have the scrape `instance`, such as `db-prod-src:9100`. Dashboards and alerts that combine both need two variables or a relabel rule. The binlog script names the server with `hostname -s`; the full backup shortens some names, so check they match.


## Testing

The tests need Linux (WSL works) but no MySQL, bucket or root:

```
bash mysql_prod_backup_script/tests/test_mysql_binlog_backup.sh
TIMEOUT_BIN=gnutimeout bash mysql_prod_backup_script/tests/test_mysql_binlog_backup.sh
```

The second line matters on Ubuntu 25.10 and later, whose default `timeout` is the uutils one; servers usually have GNU coreutils. The 29 cases cover starting a chain, normal runs, failed and hung uploads, the lock, MySQL errors, gaps, a failed first run, a damaged or unwritable tracking file, a numbering reset, the options and the log.

The script has not run against a real MySQL server or bucket yet. The first deployment on a dev server is its first real test.


## Known gaps

- The "failed precondition" hint is printed for every upload error, not only for 412.
- If `gcloud` is not found, the clear message goes to the screen before the log starts; the log only shows `failed to run command 'storage'`.
- If the node_exporter directory is missing, the run still reports `Saved Success Metrics` and exits 0.
- After "already exists" (412), the script does not compare the object with the local file; a person has to.
