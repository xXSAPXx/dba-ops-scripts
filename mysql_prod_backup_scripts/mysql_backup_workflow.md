# MySQL backup script: workflow

How [`mysql_backup_v3_aws.sh`](mysql_backup_v3_aws.sh) works. The diagrams leave the cloud out: **bucket** is the S3 or GCS bucket, and **secret store** is where the encryption key is kept (AWS Secrets Manager today). The GCP script [`mysql_backup_v3.sh`](mysql_backup_v3.sh) follows the same flow, and gets encryption and incremental backups when they are ported.

| Option | What it does |
|---|---|
| `--xtrabackup` | A full backup with XtraBackup, compressed, encrypted and uploaded to the bucket. It starts a new incremental chain. |
| `--xtrabackup_incremental` | Only the pages changed since the last backup of the chain, compressed, encrypted and uploaded. |
| `--mysql_shell` | A logical dump with MySQL Shell, uploaded (not encrypted). |
| `--xtrabackup_local`, `--mysql_shell_local` | Only the backup step (diagram 2): the backup stays in `/backup`, with no upload and no metrics. |

## 1. One run

Red: the run ends with exit 1.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart TD
    START(["cron or a person runs<br/>the script with one option"]) --> ARGS{"One valid option?"}
    ARGS -->|"no, or --help"| HELP["Print the help"]
    ARGS -->|"yes"| LOG["Start the log<br/>/var/log/mysql_backup.log"]
    LOG --> RUNLOCK{"Run lock free?<br/>(one backup at a time)"}
    RUNLOCK -->|"no: a backup still runs"| BUSY["Exit 1<br/>metrics untouched"]:::fail
    RUNLOCK -->|"yes"| BACKUP["Take the backup<br/>(diagram 2)"]
    BACKUP -->|"failed"| BFAIL["Metrics: backup failed<br/>exit 1"]:::fail
    BACKUP -->|"ok"| BOK["Metrics: backup ok"]
    BOK --> CLEAN["Delete old local backups in /backup"]
    CLEAN --> UPLOAD["Upload to the bucket<br/>(stopped after UPLOAD_TIMEOUT)"]
    UPLOAD -->|"failed"| TFAIL["Metrics: transfer failed<br/>exit 1"]:::fail
    UPLOAD -->|"ok, XtraBackup"| ADVANCE["Move the chain forward:<br/>this backup becomes the chain state"]
    ADVANCE -->|"failed"| TFAIL
    UPLOAD -->|"ok, MySQL Shell"| TOK["Metrics: transfer ok<br/>backup age reset"]
    ADVANCE -->|"ok"| TOK
    TOK -->|"incremental"| RMINC["Delete the local incremental file"]
    TOK -->|"full or MySQL Shell"| DONE(["Done"]):::ok
    RMINC --> DONE

    classDef fail fill:#ffebe9,stroke:#cf222e,color:#1f2328
    classDef ok fill:#dafbe1,stroke:#1a7f37,color:#1f2328
```

## 2. The backup step

XtraBackup, full and incremental. Each fail goes back to diagram 1 as "failed":

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart TD
    START(["--xtrabackup or<br/>--xtrabackup_incremental"]) --> TYPE{"Incremental?"}
    TYPE -->|"yes"| BASE{"Chain state exists?"}
    BASE -->|"no"| NOBASE["Fail: no base<br/>a full backup must start a chain first"]:::fail
    BASE -->|"yes"| LOCK
    TYPE -->|"no, full"| LOCK["Take the MySQL named lock backup_running<br/>(the application's TRUNCATE scripts wait for it)"]
    LOCK -->|"held by another session"| LFAIL["Fail"]:::fail
    LOCK -->|"taken"| KEY["Read the encryption key from the secret store<br/>into a file on the RAM disk (/dev/shm)"]
    KEY -->|"failed"| KFAIL["Release the lock, fail"]:::fail
    KEY -->|"ok"| XB["xtrabackup compresses (zstd) and encrypts (AES256)<br/>into /backup: TIME-dbfull.xbstream, or<br/>TIME-dbincr.xbstream with only the pages<br/>changed after the chain state.<br/>This backup's position goes to mysql_backup.state.new"]
    XB --> CLEANUP["Delete the key file, release the lock"]
    CLEANUP --> RESULT{"xtrabackup ok?"}
    RESULT -->|"no"| XFAIL["Fail"]:::fail
    RESULT -->|"yes"| DONE(["Back to diagram 1: metrics, upload"]):::ok

    classDef fail fill:#ffebe9,stroke:#cf222e,color:#1f2328
    classDef ok fill:#dafbe1,stroke:#1a7f37,color:#1f2328
```

If the script is stopped or killed during the backup, a trap deletes the key file and releases the lock. The key is never printed or written to the log.

MySQL Shell:

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart LR
    START(["--mysql_shell"]) --> LOCK["Take the MySQL named lock<br/>backup_running"]
    LOCK --> DUMP["mysqlsh util.dumpInstance<br/>into /backup (zstd)"]
    DUMP --> UNLOCK["Release the lock"]
    UNLOCK --> TAR["tar the dump folder<br/>(no second compression)"]
    TAR --> DONE(["Back to diagram 1"]):::ok

    classDef ok fill:#dafbe1,stroke:#1a7f37,color:#1f2328
```

## 3. The incremental chain

```mermaid
flowchart LR
    subgraph CHAIN1 ["Chain 1"]
        MON["Mon<br/>full"] --> TUE["Tue<br/>incremental"] --> WED["Wed<br/>incremental"]
    end
    subgraph CHAIN2 ["Chain 2"]
        THU["Thu<br/>full"] --> FRI["Fri<br/>incremental"] --> SAT["Sat<br/>incremental"] --> SUN["Sun<br/>incremental"]
    end
    WED ~~~ THU
```

- Each incremental holds only the pages changed since the backup before it. After its upload, a backup's position (`xtrabackup_checkpoints`) becomes the **chain state** in `/opt/scripts/mysql_backup.state`: the base of the next incremental.
- A failed backup or upload leaves the chain state on the last backup in the bucket, so the next incremental continues from there: the chain has no holes.
- A full backup starts a new chain. The cron example in the script header takes fulls on Monday and Thursday, and incrementals on the other days.
- To restore Saturday: Thursday's full, then Friday's and Saturday's incrementals, in this order (and the binlogs for a later moment). [`mysql_restore_v2_aws.sh`](../mysql_restore_script/mysql_restore_v2_aws.sh) does this. It also deletes the chain state, because an incremental taken on top of the old chain after a restore would miss changes without any error. Incrementals then fail until a full backup starts a new chain.
- Retention: to restore any moment of the last N days, keep every backup N + 4 days. A restore point can need a full backup up to 4 days older than itself (Thursday's full, three incrementals and a day of binlogs).

## What it writes

| Where | What |
|---|---|
| Bucket | `TIME-dbfull.xbstream` and `TIME-dbincr.xbstream` (encrypted), `full-instance-backup-TIME.tar` (MySQL Shell) |
| `/backup` | Recent backups for a quick restore: XtraBackup files are deleted after 23 hours, MySQL Shell archives after 3 days. Incrementals are deleted right after their upload. |
| `/opt/scripts/mysql_backup.state` | The chain state: the position of the last backup in the bucket |
| `/var/log/mysql_backup.log` | Every run, with colors (`less -R`) |
| node_exporter textfile folder | `node_mysql_backup_*` (full and MySQL Shell) and `node_mysql_incremental_backup_*`: status, durations, time of the last success |
