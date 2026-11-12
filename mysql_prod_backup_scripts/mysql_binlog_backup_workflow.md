# MySQL binlog backup script: workflow

How [`mysql_binlog_backup_v2.sh`](mysql_binlog_backup_v2.sh) (GCP) and [`mysql_binlog_backup_v2_aws.sh`](mysql_binlog_backup_v2_aws.sh) (AWS) work: the same logic, with different cloud commands. The diagrams leave the cloud out: **bucket** is the GCS or S3 bucket, and **secret store** is where the encryption key is kept (GCP Secret Manager or AWS Secrets Manager).

| Option | What it does |
|---|---|
| `--init_binlog_chain mysql-bin.NNNNNN` | Starts a binlog chain, once, by hand. It uploads nothing itself. `--help` shows which binlog to start from. |
| `--continuous_binlog_backup` | From cron every 15-30 minutes: encrypts every closed binlog of the chain and uploads it to the bucket. |

## 1. Starting a chain (once, by hand)

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart TD
    START(["A person runs<br/>--init_binlog_chain mysql-bin.000150"]) --> NAME{"A binlog name?"}
    NAME -->|"no"| F1["Fail"]:::fail
    NAME -->|"yes"| EXISTS{"Chain state exists?"}
    EXISTS -->|"yes"| F2["Fail: a chain is running.<br/>Delete the chain state<br/>on purpose to start over"]:::fail
    EXISTS -->|"no"| ONSERVER{"Binlog still on the server?"}
    ONSERVER -->|"no: purged"| F3["Fail: take a new full backup<br/>and start from its binlog"]:::fail
    ONSERVER -->|"yes"| WRITE["Chain state = the binlog before it<br/>(mysql-bin.000149)"]
    WRITE --> DONE(["The next cron run uploads 000150<br/>and every binlog after it"]):::ok

    classDef fail fill:#ffebe9,stroke:#cf222e,color:#1f2328
    classDef ok fill:#dafbe1,stroke:#1a7f37,color:#1f2328
```

The **chain state** (`/opt/scripts/mysql_binlog_backup.state`) always holds the last binlog in the bucket.

## 2. Every cron run

Red: the run ends with the metrics set to failed and exit 1. A failed MySQL command or encryption ends it the same way.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart TD
    START(["cron runs<br/>--continuous_binlog_backup"]) --> LOG["Start the log<br/>/var/log/mysql/mysql_binlog_backup.log"]
    LOG --> RUNLOCK{"Run lock free?"}
    RUNLOCK -->|"no: the last run is still uploading"| SKIP["Skip this run, exit 0<br/>metrics untouched"]
    RUNLOCK -->|"yes"| STATE{"Chain state exists<br/>and holds a binlog name?"}
    STATE -->|"no"| F1["Fail: no chain<br/>start one with --init_binlog_chain"]:::fail
    STATE -->|"yes"| KEY["Read the encryption key from the secret store<br/>(kept in memory only)"]
    KEY -->|"failed"| F2["Fail"]:::fail
    KEY -->|"ok"| LIST["List the binlogs (SHOW BINARY LOGS)"]
    LIST --> FLUSH["FLUSH BINARY LOGS: the last binlog in the list<br/>is closed, and a new one becomes active"]
    FLUSH --> NEXT{"Next binlog in the list<br/>after the chain state?"}
    NEXT -->|"yes"| GAP{"Its number =<br/>chain state + 1?"}
    GAP -->|"no"| F3["Fail: a gap, binlogs were<br/>purged before their upload"]:::fail
    GAP -->|"yes"| ENC["Encrypt it (xbcrypt, AES256)<br/>into /backup/binlog_upload"]
    ENC --> UPLOAD["Upload it as SERVER/DATE/mysql-bin.NNNNNN.xbcrypt<br/>(never overwrites an existing file)"]
    UPLOAD --> RMCOPY["Delete the encrypted copy"]
    RMCOPY --> UPOK{"Upload ok?"}
    UPOK -->|"no"| F4["Fail: the next run retries it"]:::fail
    UPOK -->|"yes"| SAVE["Chain state = this binlog"]
    SAVE --> NEXT
    NEXT -->|"no more"| COUNT{"At least one<br/>binlog uploaded?"}
    COUNT -->|"no"| F5["Fail: the numbering went backwards<br/>(reset, restored or rebuilt server)"]:::fail
    COUNT -->|"yes"| OK(["Metrics: ok"]):::ok

    classDef fail fill:#ffebe9,stroke:#cf222e,color:#1f2328
    classDef ok fill:#dafbe1,stroke:#1a7f37,color:#1f2328
```

An example run. The chain state holds `mysql-bin.000041`; the server has `000040` to `000044`, and `000044` is active:

1. The list is `000040` to `000044`. FLUSH closes `000044`, and `000045` becomes the active binlog.
2. `000040` and `000041` are already in the bucket: skipped.
3. `000042`, `000043` and `000044` are encrypted and uploaded, one at a time. After each upload, the chain state moves to it.
4. The chain state holds `000044`. The next run starts from `000045`.

- **A gap** (a missing binlog number) means MySQL purged binlogs before they were uploaded (`binlog_expire_logs_seconds`). Point-in-time recovery cannot cross it, so every run fails until a person takes a new full backup and starts a new chain from that backup's binlog.
- **No upload at all** means the numbering went backwards (`RESET BINARY LOGS AND GTIDS`, a rebuilt server): a new full backup and a new chain. `--help` lists which binlog to start from in each case.
- **After a restore** with [`mysql_restore_v2.sh`](../mysql_restore_script/mysql_restore_v2.sh) (AWS: [`mysql_restore_v2_aws.sh`](../mysql_restore_script/mysql_restore_v2_aws.sh)), the chain state is deleted, so every run fails until a person takes a new full backup and starts a new chain from that backup's binlog. Without this, the restored server's new binlogs would go into the old chain without an error.
- Each server has its own folder in the bucket, and an upload never overwrites a file: a binlog with the same name from another sequence makes the upload fail instead.
- Retention: keep the binlogs as long as the full backups (N + 4 days, see [the backup workflow](mysql_backup_workflow.md)).

## Cron

`/etc/cron.d/mysql_binlog_backup`, every 15 minutes (on AWS, `mysql_binlog_backup_v2_aws.sh`):

```
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * root /opt/scripts/mysql_binlog_backup_v2.sh --continuous_binlog_backup > /dev/null 2>&1
```

- **`PATH`:** cron's own is short, and the script finds the cloud CLI with `which`. Without it, a CLI in `/usr/local/bin` looks not installed and the backup fails.
- **Start the chain by hand before enabling it:** `--init_binlog_chain mysql-bin.NNNNNN` (`--help` shows which binlog). Otherwise every run fails with "No binlog chain to continue".
- **How often:** every 15-30 minutes. The binlogs of that time, and the active one, are not in the bucket yet, so this is how much a lost server can lose.
- **The output:** the script logs itself to `/var/log/mysql/mysql_binlog_backup.log`, so cron's copy goes to `/dev/null`.
- **The file:** owned by root, mode 644, ending with a new line, and with no dot in its name, or cron ignores it. The script needs `chmod 700`.
- **A slow upload:** a run that finds the last one still uploading skips with exit 0, so it never piles up.

## What it writes

| Where | What |
|---|---|
| Bucket | `SERVER/DATE/mysql-bin.NNNNNN.xbcrypt` (encrypted) |
| `/backup/binlog_upload` | One encrypted binlog during its upload, deleted after it |
| `/opt/scripts/mysql_binlog_backup.state` | The chain state: the last binlog in the bucket |
| `/var/log/mysql/mysql_binlog_backup.log` | Every run, with colors (`less -R`) |
| node_exporter textfile folder | `node_mysql_binlog_backup_status` (0 ok, 1 failed), `node_mysql_binlog_backup_duration_seconds`, `node_mysql_current_active_binlog`, `node_mysql_last_backed_up_binlog`, `node_mysql_last_successful_binlog_backup_date` |
