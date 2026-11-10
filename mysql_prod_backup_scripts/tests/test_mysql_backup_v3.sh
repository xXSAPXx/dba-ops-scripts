#!/bin/bash

# Tests mysql_backup_v3.sh against a mocked MySQL, xtrabackup, xbcrypt, mysqlsh and gcloud. No MySQL server, bucket or root needed.
#
# Run on Linux (WSL works):         bash mysql_prod_backup_scripts/tests/test_mysql_backup_v3.sh
# With GNU timeout where the default timeout is uutils (Ubuntu 25.10+, as on WSL Ubuntu 26.04):
#                                    TIMEOUT_BIN=gnutimeout bash mysql_prod_backup_scripts/tests/test_mysql_backup_v3.sh
#
# The script is copied with its paths pointed at a temporary directory, a 2 s upload timeout and a 3 s wait for GET_LOCK.
# Each case checks the exit code and the output, plus a condition, and the run ends with a PASS/FAIL count.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../mysql_backup_v3.sh"
T=$(mktemp -d /tmp/backuptest.XXXX)
mkdir -p "$T/bin" "$T/backup" "$T/bucket" "$T/textfile" "$T/datadir" "$T/state" "$T/shm"
KEY=abcdefghijklmnopqrstuvwxyz012345

# Hung uploads and lock holders leave processes behind; kill them at the end.
cleanup(){
    [ -f "$T/pids" ] && xargs -r kill -9 < "$T/pids" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

bash -n "$SRC" || { echo "FAIL  syntax check of $SRC"; exit 1; }

sed -e "s|^DATA_DIR=.*|DATA_DIR=\"$T/datadir\"|" \
    -e "s|^BACKUP_DIR=.*|BACKUP_DIR=\"$T/backup\"|" \
    -e "s|^GCP_BUCKET=.*|GCP_BUCKET=\"gs://test-bucket\"|" \
    -e "s|^LSN_DIR=.*|LSN_DIR=\"$T/state/lsn\"|" \
    -e "s|^NEW_LSN_DIR=.*|NEW_LSN_DIR=\"$T/state/lsn.new\"|" \
    -e "s|mktemp -p /dev/shm|mktemp -p $T/shm|" \
    -e "s|^TEXTFILE_COLLECTOR_DIR=.*|TEXTFILE_COLLECTOR_DIR=\"$T/textfile/\"|" \
    -e "s|^LOCK_FILE=.*|LOCK_FILE=\"$T/run.lock\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/backup.log\"|" \
    -e 's|^UPLOAD_TIMEOUT=.*|UPLOAD_TIMEOUT="2s"|' \
    -e 's|--kill-after=1m|--kill-after=2s|' \
    -e 's|while \[ "\$WAITED" -lt 600 \]|while [ "$WAITED" -lt 30 ]|' \
    -e "s|^\( *\)timeout --kill-after|\1${TIMEOUT_BIN:-timeout} --kill-after|" "$SRC" > "$T/backup.sh"

REPLACED=$(grep -cE "^(DATA_DIR|BACKUP_DIR|GCP_BUCKET|LSN_DIR|NEW_LSN_DIR|TEXTFILE_COLLECTOR_DIR|LOCK_FILE|LOG_FILE|UPLOAD_TIMEOUT)=" "$T/backup.sh")
[ "$REPLACED" -eq 9 ] && grep -q "mktemp -p $T/shm" "$T/backup.sh" && [ "$(grep -c -- "${TIMEOUT_BIN:-timeout} --kill-after=2s" "$T/backup.sh")" -eq 2 ] && grep -q 'while \[ "$WAITED" -lt 30 \]' "$T/backup.sh" || {
    echo "FAIL  could not point the script's settings at the test directory (did a variable name change?)"; exit 1; }
# The same script with another run lock file: two runs that the run lock cannot stop (as if started on two hosts):
sed "s|^LOCK_FILE=.*|LOCK_FILE=\"$T/other.lock\"|" "$T/backup.sh" > "$T/backup_otherlock.sh"
sed "s|^LOCK_FILE=.*|LOCK_FILE=\"/nonexistent/dir/run.lock\"|" "$T/backup.sh" > "$T/backup_badlock.sh"
echo "Testing $SRC with $(${TIMEOUT_BIN:-timeout} --version | head -n 1)"
echo


# Mock mysql: without -e it is a session reading statements from stdin, like the lock session.
# The named lock is the file $T/dblock holding the PID of the session that has it; a session that ends releases its lock, as in MySQL.
# MYSQL_CONNECT_ERROR fails the connection, GET_LOCK_ANSWER replaces the answer, GET_LOCK_NO_ANSWER never answers.
cat > "$T/bin/mysql" <<'EOF'
#!/bin/bash
echo "$*" >> "$T/mysql.args"
for a in "$@"; do [ "$a" = -e ] && { echo "mock mysql: v3 should not send -e queries: $*" >&2; exit 1; }; done
[ -n "${MYSQL_CONNECT_ERROR:-}" ] && { echo "ERROR 2002 (HY000): Can't connect to local MySQL server through socket '/var/lib/mysql/mysql.sock' (2)" >&2; exit 1; }
release(){ [ "$(cat "$T/dblock" 2>/dev/null)" = "$$" ] && rm -f "$T/dblock"; }
trap release EXIT
while IFS= read -r line; do
    case "$line" in
        *"GET_LOCK('backup_running',0)"*)
            [ -n "${GET_LOCK_NO_ANSWER:-}" ] && continue
            [ -n "${GET_LOCK_ANSWER:-}" ] && { echo "$GET_LOCK_ANSWER"; continue; }
            holder=$(cat "$T/dblock" 2>/dev/null)
            if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then echo 0; else echo $$ > "$T/dblock"; echo 1; fi;;
    esac
done
EOF

# Mock xtrabackup: records its arguments, the key it was given and whether the named lock is held, writes a stream to stdout,
# and an LSN that grows into the folder of --extra-lsndir, as the real one does.
cat > "$T/bin/xtrabackup" <<'EOF'
#!/bin/bash
echo "$*" > "$T/xtrabackup.args"
h=$(cat "$T/dblock" 2>/dev/null); { [ -n "$h" ] && kill -0 "$h" 2>/dev/null && echo held || echo free; } > "$T/lock_during_backup"
touch "$T/xtrabackup.started"
[ -n "${XTRABACKUP_SLEEP:-}" ] && sleep "$XTRABACKUP_SLEEP"
[ -n "${XTRABACKUP_FAIL:-}" ] && { echo "xtrabackup: Error: failed to execute query 'LOCK INSTANCE FOR BACKUP'" >&2; exit 1; }
for a in "$@"; do case "$a" in
    --encrypt-key-file=*) cat "${a#*=}" > "$T/key_seen";;
    --extra-lsndir=*) mkdir -p "${a#*=}"; n=$(( $(cat "$T/lsn" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/lsn"; echo "to_lsn = $n" > "${a#*=}/xtrabackup_checkpoints";;
esac; done
echo "xbstream data"
echo "completed OK!" >&2
EOF

# Mock mysqlsh: reads the JavaScript from stdin and creates the dump folder of util.dumpInstance.
cat > "$T/bin/mysqlsh" <<'EOF'
#!/bin/bash
dir=$(sed -n "s/.*util.dumpInstance('\([^']*\)'.*/\1/p")
h=$(cat "$T/dblock" 2>/dev/null); { [ -n "$h" ] && kill -0 "$h" 2>/dev/null && echo held || echo free; } > "$T/lock_during_backup"
[ -n "${MYSQLSH_FAIL:-}" ] && { echo "Util.dumpInstance: Access denied; you need (at least one of) the BACKUP_ADMIN privilege(s)" >&2; exit 1; }
mkdir -p "$dir" && echo chunk > "$dir/db@table@@0.tsv.zst" && echo '{}' > "$dir/@.json"
EOF

# Mock xbcrypt: passes the data through, so the archive can be read, and records its arguments and the key it was given.
cat > "$T/bin/xbcrypt" <<'EOF'
#!/bin/bash
echo "$*" > "$T/xbcrypt.args"
for a in "$@"; do case "$a" in --encrypt-key-file=*) cat "${a#*=}" > "$T/key_seen";; esac; done
[ -n "${XBCRYPT_FAIL:-}" ] && { cat > /dev/null; echo "xbcrypt: failed" >&2; exit 1; }
cat
EOF

# Mock gcloud: secrets versions access latest --secret=NAME --impersonate-service-account=SA prints the key (KEY_FAIL fails it,
# KEY_VALUE replaces it).
# storage cp SRC gs://DST, into $T/bucket. UPLOAD_FAIL fails it, UPLOAD_HANG hangs it, UPLOAD_HANG_HARD also ignores the stop signal.
# The hang runs in a child process, like gcloud's own workers, to check that a survivor does not keep the run lock.
cat > "$T/bin/gcloud" <<'EOF'
#!/bin/bash
if [ "$1 $2 $3 $4" = "secrets versions access latest" ]; then
    [ "$5" = "--secret=<ENCRYPT_KEY>" ] || { echo "mock gcloud: unexpected secret: $5" >&2; exit 2; }
    [ "$6" = "--impersonate-service-account=<SERVICE_ACCOUNT>" ] || { echo "mock gcloud: unexpected service account: $6" >&2; exit 2; }
    [ -n "${KEY_FAIL:-}" ] && { echo "ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: Permission denied" >&2; exit 1; }
    printf '%s\n' "${KEY_VALUE:-abcdefghijklmnopqrstuvwxyz012345}"
    exit 0
fi
[ "$1 $2" = "storage cp" ] || { echo "mock gcloud: unexpected arguments: $*" >&2; exit 2; }
src="$3"; dst="$T/bucket/${4#gs://}"
[ -e "/proc/$$/fd/9" ] && echo yes > "$T/gcloud_has_fd9"
[ -n "${UPLOAD_FAIL:-}" ] && { echo "ERROR: (gcloud.storage.cp) HTTPError 503: Service unavailable" >&2; exit 1; }
[ -n "${UPLOAD_HANG:-}" ] && { sleep 600 & echo $! >> "$T/pids"; wait; }
[ -n "${UPLOAD_HANG_HARD:-}" ] && { trap '' TERM; sleep 600 & echo $! >> "$T/pids"; wait; }
mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"
EOF

printf '#!/bin/bash\necho db-test-prod-src\n' > "$T/bin/hostname"
chmod +x "$T"/bin/*
export T PATH="$T/bin:$PATH"


# run SCRIPT OPTION: one run; its output (without colors) goes to $T/out, its exit code to RC
# The output goes through tee (the log), which can finish a moment after the script, hence the short wait:
run_script(){ local s="$1"; shift; bash "$s" "$@" > "$T/out" 2>&1; RC=$?; sleep 0.3; sed -i 's/\x1b\[[0-9;]*m//g' "$T/out"; cat "$T/out" >> "$T/all_out"; }
run(){ run_script "$T/backup.sh" "$@"; }
# fresh: empty backup folder, bucket and records of the last run (metrics stay)
fresh(){ rm -rf "$T"/backup/* "$T"/bucket/* "$T/xtrabackup.args" "$T/xtrabackup.started" "$T/lock_during_backup" "$T/gcloud_has_fd9" "$T/xbcrypt.args" "$T/key_seen" "$T"/shm/*; }

PASSED=0; FAILED=0
# check NAME EXIT [TEXT] [CONDITION]: EXIT "-" skips the exit code, CONDITION is a shell test
check(){
    local name="$1" want_rc="$2" text="${3:-}" cond="${4:-}" problems=""
    [ "$want_rc" = "-" ] || [ "$RC" = "$want_rc" ] || problems+=" exit $RC, expected $want_rc;"
    [ -z "$text" ] || grep -qF -- "$text" "$T/out" || problems+=" output lacks '$text';"
    [ -z "$cond" ] || eval "$cond" || problems+=" failed: $cond;"
    if [ -z "$problems" ]; then
        PASSED=$((PASSED + 1)); echo "PASS  $name"
    else
        FAILED=$((FAILED + 1)); echo "FAIL  $name:$problems"; sed 's/^/        /' "$T/out" | tail -n 15
    fi
}

metric(){ awk -v m="$1" 'index($0, m "{") == 1 {v=$2} END {print v}' "$T/textfile/mysql_backup_status.prom" 2>/dev/null; }
inc_metric(){ awk -v m="$1" 'index($0, m "{") == 1 {v=$2} END {print v}' "$T/textfile/mysql_incremental_backup_status.prom" 2>/dev/null; }
shell_metric(){ awk -v m="$1" 'index($0, m "{") == 1 {v=$2} END {print v}' "$T/textfile/mysql_shell_backup_status.prom" 2>/dev/null; }
to_lsn(){ awk '/^to_lsn/ {print $3}' "$T/state/lsn/xtrabackup_checkpoints" 2>/dev/null; }
no_key_left(){ [ -z "$(ls -A "$T/shm")" ]; }
db_lock_held(){ local h; h=$(cat "$T/dblock" 2>/dev/null); [ -n "$h" ] && kill -0 "$h" 2>/dev/null; }
# The lock session ends a moment after the script closes its input:
db_lock_released(){ for _ in $(seq 30); do db_lock_held || return 0; sleep 0.1; done; return 1; }
wait_for(){ for _ in $(seq 50); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
uploads(){ find "$T/bucket" -type f | wc -l; }


echo "--- xtrabackup"
fresh; run --xtrabackup
check "backup and upload succeed" 0 "Saved Successful Transfer Metrics for XtraBackup" '[ "$(uploads)" = 1 ] && [ "$(metric node_mysql_backup_status)" = 0 ] && [ "$(metric node_mysql_backup_transfer_status)" = 0 ]'
check "the backup ran while the named lock was held" - "Lock acquired successfully" '[ "$(cat "$T/lock_during_backup")" = held ]'
check "the named lock is released after the backup" - "has been released" 'db_lock_released'
check "the lock session runs with --unbuffered" - "" 'grep -q -- --unbuffered "$T/mysql.args"'
check "xtrabackup runs without --no-server-version-check" - "" '! grep -q -- --no-server-version-check "$T/xtrabackup.args"'
check "gcloud does not inherit the run lock (fd 9)" - "" '[ ! -e "$T/gcloud_has_fd9" ]'
check "the size metric is the size of the backup file" - "" '[ "$(metric node_mysql_backup_size_bytes)" = "$(stat -c %s "$(find "$T/bucket" -name "*-dbfull.xbstream")")" ] && [ "$(metric node_mysql_backup_size_bytes)" -gt 0 ]'
check "each metric is in the status file once" - "" '[ -z "$(awk "{print \$1}" "$T/textfile/mysql_backup_status.prom" | sort | uniq -d)" ]'
check "the backup is encrypted with the key from Secret Manager, in a file, not on a command line" - "Encryption key read from GCP Secret Manager" 'grep -q -- "--encrypt=AES256 --encrypt-key-file=$T/shm/mysql_backup_key\." "$T/xtrabackup.args" && [ "$(cat "$T/key_seen")" = "$KEY" ] && [ "$(wc -c < "$T/key_seen")" = 32 ] && ! grep -q "$KEY" "$T/xtrabackup.args" "$T/out" "$T/backup.log"'
check "the key file is gone from the RAM disk after the backup" - "" 'no_key_left'
check "a full backup starts the incremental chain" - "Backup chain moved forward" '[ -f "$T/state/lsn/xtrabackup_checkpoints" ] && [ ! -e "$T/state/lsn.new" ]'

echo "--- the encryption key"
fresh; KEY_FAIL=1 run --xtrabackup
check "secret not readable: the backup does not start, lock released" 1 "Unable to read the encryption key <ENCRYPT_KEY> from GCP Secret Manager as <SERVICE_ACCOUNT>" '[ ! -e "$T/xtrabackup.args" ] && [ "$(metric node_mysql_backup_status)" = 1 ] && db_lock_released && no_key_left'
fresh; KEY_VALUE=short run --xtrabackup
check "key of the wrong length: the backup does not start" 1 "has 5 characters instead of 32" '[ ! -e "$T/xtrabackup.args" ] && db_lock_released && no_key_left'

echo "--- the incremental chain"
fresh; rm -rf "$T"/state/*; run --xtrabackup_incremental
check "no base: the incremental fails and says to take a full backup" 1 "No base for the incremental backup" '[ ! -e "$T/xtrabackup.args" ] && [ "$(uploads)" = 0 ] && [ "$(inc_metric node_mysql_incremental_backup_status)" = 1 ]'
fresh; run --xtrabackup; FULL_LSN=$(to_lsn)
fresh; run --xtrabackup_incremental
check "incremental from the last backup, uploaded as dbincr, its own metrics" 0 "Saved Successful Transfer Metrics for Incremental XtraBackup" 'grep -q -- "--incremental-basedir=$T/state/lsn " "$T/xtrabackup.args" && [ "$(find "$T/bucket" -name "*-dbincr.xbstream" | wc -l)" = 1 ] && [ "$(inc_metric node_mysql_incremental_backup_status)" = 0 ] && [ "$(inc_metric node_mysql_incremental_backup_transfer_status)" = 0 ]'
check "the incremental has its own size metric, the size of its file" - "" '[ "$(inc_metric node_mysql_incremental_backup_size_bytes)" = "$(stat -c %s "$(find "$T/bucket" -name "*-dbincr.xbstream")")" ]'
check "the chain moved forward, and the local copy is gone" - "" '[ "$(to_lsn)" != "$FULL_LSN" ] && [ -z "$(find "$T/backup" -name "*-dbincr.xbstream")" ] && no_key_left'
INC_LSN=$(to_lsn)
fresh; UPLOAD_FAIL=1 run --xtrabackup_incremental
check "failed upload: the chain stays on the last backup in the bucket, the local copy stays" 1 "Transfer to GCP Bucket Failed! (XtraBackup)" '[ "$(to_lsn)" = "$INC_LSN" ] && [ "$(find "$T/backup" -name "*-dbincr.xbstream" | wc -l)" = 1 ] && [ "$(inc_metric node_mysql_incremental_backup_transfer_status)" = 1 ]'
fresh; XTRABACKUP_FAIL=1 run --xtrabackup_incremental
check "failed backup: the chain stays, lock released" 1 "Incremental XtraBackup failed." '[ "$(to_lsn)" = "$INC_LSN" ] && db_lock_released && no_key_left'
fresh; UPLOAD_FAIL=1 run --xtrabackup
check "a full backup whose upload failed does not start a new chain" 1 "Transfer to GCP Bucket Failed! (XtraBackup)" '[ "$(to_lsn)" = "$INC_LSN" ]'

echo "--- the named lock"
fresh; sleep 600 & APP=$!; echo $APP >> "$T/pids"; echo $APP > "$T/dblock"
run --xtrabackup
check "lock held by an application script: the backup does not start" 1 "is held by another session" '[ ! -e "$T/xtrabackup.args" ] && [ "$(metric node_mysql_backup_status)" = 1 ]'
check "the application keeps its lock" - "" '[ "$(cat "$T/dblock")" = "$APP" ]'
kill $APP; rm -f "$T/dblock"

fresh; MYSQL_CONNECT_ERROR=1 run --xtrabackup
check "MySQL down: fails with a message, the script does not die" 1 "no answer from MySQL to GET_LOCK" 'grep -q "Saved Failure Metrics for XtraBackup" "$T/out" && [ ! -e "$T/xtrabackup.args" ]'
fresh; GET_LOCK_ANSWER=NULL run --xtrabackup
check "GET_LOCK returns NULL: the backup does not start" 1 "got: 'NULL'" '[ ! -e "$T/xtrabackup.args" ]'
fresh; GET_LOCK_NO_ANSWER=1 run --xtrabackup
check "no answer to GET_LOCK: fails after the wait" 1 "no answer from MySQL to GET_LOCK" '[ ! -e "$T/xtrabackup.args" ] && db_lock_released'

fresh; XTRABACKUP_SLEEP=3 bash "$T/backup_otherlock.sh" --xtrabackup > "$T/out_a" 2>&1 & A=$!
wait_for "$T/xtrabackup.started"; run --xtrabackup
check "two backups that the run lock cannot stop: only one gets the named lock" 1 "is held by another session" ''
wait $A; RC=$?; sleep 0.3; cp "$T/out_a" "$T/out"
check "the other backup finishes normally" 0 "Saved Successful Transfer Metrics for XtraBackup" 'db_lock_released'

fresh; XTRABACKUP_FAIL=1 run --xtrabackup
check "xtrabackup fails: no size metric for a failed backup" 1 "XtraBackup failed." '[ -z "$(metric node_mysql_backup_size_bytes)" ]'
check "xtrabackup fails: failure metrics, lock released, nothing uploaded" 1 "XtraBackup failed." '[ "$(metric node_mysql_backup_status)" = 1 ] && db_lock_released && [ "$(uploads)" = 0 ]'

fresh; XTRABACKUP_SLEEP=3 bash "$T/backup.sh" --xtrabackup > "$T/out" 2>&1 & S=$!
wait_for "$T/xtrabackup.started"; kill -9 $S; wait $S 2>/dev/null; sleep 0.5; RC=-
check "script killed (kill -9): the named lock stays held while xtrabackup runs" - "" 'db_lock_held'
run --xtrabackup_local
check "script killed: the run lock stays held while xtrabackup runs" 1 "Another backup is still running" ''
check "script killed: the named lock is released when xtrabackup ends" - "" 'for _ in $(seq 60); do db_lock_held || break; sleep 0.1; done; ! db_lock_held'
flock -w 10 "$T/run.lock" true  # the orphaned xtrabackup still holds the run lock for a moment

echo "--- the run lock (flock)"
fresh; XTRABACKUP_SLEEP=2 bash "$T/backup.sh" --xtrabackup > "$T/out_a" 2>&1 & A=$!
wait_for "$T/xtrabackup.started"; BEFORE=$(cat "$T/textfile/mysql_backup_status.prom")
run --xtrabackup
check "second run while one is running: refused, metrics untouched" 1 "Another backup is still running" '[ "$(cat "$T/textfile/mysql_backup_status.prom")" = "$BEFORE" ]'
wait $A; RC=$?; sleep 0.3; cp "$T/out_a" "$T/out"
check "the first run finishes normally" 0 "Saved Successful Transfer Metrics for XtraBackup"
run_script "$T/backup_badlock.sh" --xtrabackup
check "run lock file cannot be opened: the run fails" 1 "Unable to open the lock file"
( exec 9> "$T/run.lock"; flock 9; sleep 3 ) & H=$!; sleep 0.5
run --help;              check "--help works while a backup runs" 0 "Available Backup Options"
run --mysql_shell_local; check "local backups are refused while a backup runs" 1 "Another backup is still running"
wait $H

echo "--- uploads"
fresh; UPLOAD_FAIL=1 run --xtrabackup
check "failed upload: transfer failure metrics" 1 "Transfer to GCP Bucket Failed! (XtraBackup)" '[ "$(metric node_mysql_backup_status)" = 0 ] && [ "$(metric node_mysql_backup_transfer_status)" = 1 ]'
fresh; UPLOAD_HANG=1 run --xtrabackup
check "hung upload is stopped by the timeout" 1 "did not finish within 2s and was stopped" '[ "$(metric node_mysql_backup_transfer_status)" = 1 ]'
fresh; UPLOAD_HANG_HARD=1 run --xtrabackup
check "hung upload that ignores the stop signal is killed" 1 "did not finish within 2s and was stopped"
fresh; run --xtrabackup
check "next run is not blocked by a leftover upload process" 0 "Saved Successful Transfer Metrics for XtraBackup"

echo "--- MySQL Shell"
fresh
touch -d "4 days ago" "$T/backup/full-instance-backup-old.tar" "$T/backup/full-instance-backup-old.tar.gz"
touch -d "1 day ago" "$T/backup/full-instance-backup-recent.tar"
cp "$T/textfile/mysql_backup_status.prom" "$T/full_status.before"; cp "$T/textfile/mysql_backup_age.prom" "$T/full_age.before"
run --mysql_shell
check "MySQL Shell backup and upload succeed" 0 "Saved Successful Transfer Metrics for MySQL Shell Backup" '[ "$(find "$T/bucket" -name "full-instance-backup-*.tar.xbcrypt" | wc -l)" = 1 ] && [ "$(cat "$T/lock_during_backup")" = held ] && db_lock_released'
check "MySQL Shell writes its own metrics, and the full backup's stay as they were" - "" '[ "$(shell_metric node_mysql_shell_backup_status)" = 0 ] && [ "$(shell_metric node_mysql_shell_backup_transfer_status)" = 0 ] && grep -q "^node_mysql_last_successful_shell_backup_date" "$T/textfile/mysql_shell_backup_age.prom" && cmp -s "$T/full_status.before" "$T/textfile/mysql_backup_status.prom" && cmp -s "$T/full_age.before" "$T/textfile/mysql_backup_age.prom"'
check "MySQL Shell: the size metric is the size of the archive" - "" '[ "$(shell_metric node_mysql_shell_backup_size_bytes)" = "$(stat -c %s "$(find "$T/bucket" -name "full-instance-backup-*.tar.xbcrypt")")" ]'
check "the archive goes through xbcrypt with the key file, and the key file is gone after it" - "" 'grep -q -- "--encrypt-algo=AES256 --encrypt-key-file=$T/shm/mysql_backup_key\." "$T/xbcrypt.args" && [ "$(cat "$T/key_seen")" = "$KEY" ] && no_key_left'
check "the archive is a plain tar (not compressed again) with the dump folder at its top" - "" 'A=$(find "$T/bucket" -name "full-instance-backup-*.tar.xbcrypt"); ! gzip -t "$A" 2>/dev/null && tar -tf "$A" | grep -q "^full-instance-backup-.*-mysql-shell/@.json$" && ! tar -tf "$A" | grep -qv "^full-instance-backup-.*-mysql-shell/"'
check "cleanup removes .tar and .tar.gz archives older than 3 days, keeps newer ones" - "" '[ ! -e "$T/backup/full-instance-backup-old.tar" ] && [ ! -e "$T/backup/full-instance-backup-old.tar.gz" ] && [ -e "$T/backup/full-instance-backup-recent.tar" ]'
fresh; MYSQLSH_FAIL=1 run --mysql_shell
check "MySQL Shell fails: failure metrics, lock released" 1 "MySQL Shell Backup Failed!" '[ "$(shell_metric node_mysql_shell_backup_status)" = 1 ] && db_lock_released'
fresh; XBCRYPT_FAIL=1 run --mysql_shell
check "xbcrypt fails: failure metrics, nothing uploaded, no key left" 1 "Backup Folder Archive Failed!" '[ "$(uploads)" = 0 ] && db_lock_released && no_key_left'
fresh; UPLOAD_HANG=1 run --mysql_shell
check "MySQL Shell: hung upload is stopped by the timeout" 1 "did not finish within 2s and was stopped"

echo "--- local backups and options"
fresh; cp "$T/textfile/mysql_backup_status.prom" "$T/status.before"
run --xtrabackup_local
check "--xtrabackup_local: backup only, no upload, metrics untouched" 0 "Local XtraBackup Finished Successfully" '[ "$(uploads)" = 0 ] && cmp -s "$T/status.before" "$T/textfile/mysql_backup_status.prom" && db_lock_released'
fresh; run --mysql_shell_local
check "--mysql_shell_local: backup only, no upload" 0 "Local MySQL Shell Backup Finished Successfully" '[ "$(uploads)" = 0 ]'
run;              check "no option is rejected" 1 "Exactly one argument is required (got 0)"
fresh; run --xtrabackup --mysql_shell
check "two options are rejected, nothing runs" 1 "Exactly one argument is required (got 2)" '[ ! -e "$T/xtrabackup.args" ] && [ "$(uploads)" = 0 ]'
run --full;       check "an unknown option is rejected" 1 "Invalid argument '--full'"
cat "$T/out_a" >> "$T/all_out"; cp "$T/all_out" "$T/out"; RC=-
check "no run printed a shell error" - "" '! grep -nE "unbound variable|Bad file descriptor|command not found|syntax error|ambiguous redirect" "$T/all_out"'

echo "--- the log"
L="$T/backup.log"
check "every backup run is logged, with its header line" - "" '[ "$(grep -c "| db-test-prod-src | --" "$L")" -ge 20 ] && grep -q "| db-test-prod-src | --mysql_shell_local =====" "$L"'
check "the log keeps earlier runs, refused ones too, with their colors" - "" 'grep -q "Saved Successful Transfer Metrics for MySQL Shell Backup" "$L" && grep -q "Another backup is still running" "$L" && grep -q $'"'"'\e\['"'"' "$L"'
check "--help, unknown and missing options are not logged" - "" '! grep -qE "\| db-test-prod-src \| (--help|--full|) =====" "$L"'
mv "$T/bin/gcloud" "$T/bin/gcloud.off"
fresh; run --xtrabackup
check "gcloud missing: the error reaches the log, the upload fails" 1 "gcloud CLI is not installed" 'grep -q "gcloud CLI is not installed" "$L" && [ "$(metric node_mysql_backup_transfer_status)" = 1 ]'
fresh; run --xtrabackup_local
check "gcloud missing: a local backup fails too, since it cannot read the key" 1 "the encryption key cannot be read from GCP Secret Manager" '! grep -q "Please install Google Cloud SDK" "$T/out" && [ ! -e "$T/xtrabackup.args" ]'
mv "$T/bin/gcloud.off" "$T/bin/gcloud"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
