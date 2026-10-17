# Script_Collection (local folder: dba-ops-scripts)

Bash and Python tools for running MySQL in production: backups to Google Cloud Storage, restore, and monitoring helpers. Each folder holds one tool. The owner is a DBA. The servers look RHEL-family (the `mysqld` service, `/var/lib/mysql/mysql.sock`), so expect GNU coreutils there; confirm before relying on it.

## Before changing a script

- For the binlog backup, keep the script's `--help` and its tests in step with any change.
- Bash conventions used across the scripts: `set -uo pipefail` without `-e` (each step checks its own result and returns 1), color variables for output, one function per job, `main` with a `case` on the option, a `--help` option.
- Metrics go to node_exporter's textfile collector, written to a temporary file and renamed. Status metrics use `0` for success and `1` for failure.

## Testing

- `mysql_prod_backup_script/tests/test_mysql_binlog_backup.sh` runs the binlog script against a mocked MySQL and gcloud. From Windows: `wsl -d Ubuntu -e bash <path under /mnt/c>`.
- Run it twice: with the default `timeout` and with `TIMEOUT_BIN=gnutimeout`. WSL Ubuntu 26.04 uses uutils coreutils by default; the servers have GNU, and the two behave differently when killing hung processes.
- When last checked (October 2026), Node and Python were not installed on the Windows host or in WSL, and Docker Desktop's engine was not running.

## Git

- Work on a branch, push it, and give the owner a prefilled GitHub compare link (`https://github.com/xXSAPXx/Script_Collection/compare/main...<branch>?quick_pull=1&title=...&body=...`, URL-encoded). The owner merges.
- Stage files by name, never `git add -A`. Before pushing to an existing branch, `git fetch --prune` and check it was not merged already.
- `*.sh` files are forced to LF line endings by `.gitattributes`.
