#!/bin/bash

# Tests mysql_backup_v3.sh against a mocked MySQL, xtrabackup, mysqlsh and gcloud. No MySQL server, bucket or root needed.
#
# Run on Linux (WSL works):         bash mysql_prod_backup_script/tests/test_mysql_backup_v3.sh
# With GNU timeout where the default timeout is uutils (Ubuntu 25.10+, as on WSL Ubuntu 26.04):
#                                    TIMEOUT_BIN=gnutimeout bash mysql_prod_backup_script/tests/test_mysql_backup_v3.sh
#
# The script is copied with its paths pointed at a temporary directory, a 2 s upload timeout and a 3 s wait for GET_LOCK.
# Each case checks the exit code and the output, plus a condition, and the run ends with a PASS/FAIL count.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../mysql_backup_v3.sh"
T=$(mktemp -d /tmp/backuptest.XXXX)
mkdir -p "$T/bin" "$T/backup" "$T/bucket" "$T/textfile" "$T/datadir"

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
    -e "s|^TEXTFILE_COLLECTOR_DIR=.*|TEXTFILE_COLLECTOR_DIR=\"$T/textfile/\"|" \
    -e "s|^LOCK_FILE=.*|LOCK_FILE=\"$T/run.lock\"|" \
    -e 's|^UPLOAD_TIMEOUT=.*|UPLOAD_TIMEOUT="2s"|' \
    -e 's|--kill-after=1m|--kill-after=2s|' \
    -e 's|while \[ "\$WAITED" -lt 600 \]|while [ "$WAITED" -lt 30 ]|' \
    -e "s|^\( *\)timeout --kill-after|\1${TIMEOUT_BIN:-timeout} --kill-after|" "$SRC" > "$T/backup.sh"

REPLACED=$(grep -cE "^(DATA_DIR|BACKUP_DIR|GCP_BUCKET|TEXTFILE_COLLECTOR_DIR|LOCK_FILE|UPLOAD_TIMEOUT)=" "$T/backup.sh")
[ "$REPLACED" -eq 6 ] && [ "$(grep -c -- "${TIMEOUT_BIN:-timeout} --kill-after=2s" "$T/backup.sh")" -eq 2 ] && grep -q 'while \[ "$WAITED" -lt 30 \]' "$T/backup.sh" || {
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

# Mock xtrabackup: records its arguments and whether the named lock is held, writes a stream to stdout.
cat > "$T/bin/xtrabackup" <<'EOF'
#!/bin/bash
echo "$*" > "$T/xtrabackup.args"
h=$(cat "$T/dblock" 2>/dev/null); { [ -n "$h" ] && kill -0 "$h" 2>/dev/null && echo held || echo free; } > "$T/lock_during_backup"
touch "$T/xtrabackup.started"
[ -n "${XTRABACKUP_SLEEP:-}" ] && sleep "$XTRABACKUP_SLEEP"
[ -n "${XTRABACKUP_FAIL:-}" ] && { echo "xtrabackup: Error: failed to execute query 'LOCK INSTANCE FOR BACKUP'" >&2; exit 1; }
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

# Mock gcloud: storage cp SRC gs://DST, into $T/bucket. UPLOAD_FAIL fails it, UPLOAD_HANG hangs it, UPLOAD_HANG_HARD also ignores the stop signal.
# The hang runs in a child process, like gcloud's own workers, to check that a survivor does not keep the run lock.
cat > "$T/bin/gcloud" <<'EOF'
#!/bin/bash
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
run_script(){ local s="$1"; shift; bash "$s" "$@" > "$T/out" 2>&1; RC=$?; sed -i 's/\x1b\[[0-9;]*m//g' "$T/out"; cat "$T/out" >> "$T/all_out"; }
run(){ run_script "$T/backup.sh" "$@"; }
# fresh: empty backup folder, bucket and records of the last run (metrics stay)
fresh(){ rm -rf "$T"/backup/* "$T"/bucket/* "$T/xtrabackup.args" "$T/xtrabackup.started" "$T/lock_during_backup" "$T/gcloud_has_fd9"; }

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
check "each metric is in the status file once" - "" '[ -z "$(awk "{print \$1}" "$T/textfile/mysql_backup_status.prom" | sort | uniq -d)" ]'

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
wait $A; RC=$?; cp "$T/out_a" "$T/out"
check "the other backup finishes normally" 0 "Saved Successful Transfer Metrics for XtraBackup" 'db_lock_released'

fresh; XTRABACKUP_FAIL=1 run --xtrabackup
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
wait $A; RC=$?; cp "$T/out_a" "$T/out"
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
fresh; run --mysql_shell
check "MySQL Shell backup and upload succeed" 0 "Saved Successful Transfer Metrics for MySQL Shell Backup" '[ "$(find "$T/bucket" -name "full-instance-backup-*.tar.gz" | wc -l)" = 1 ] && [ "$(cat "$T/lock_during_backup")" = held ] && db_lock_released'
fresh; MYSQLSH_FAIL=1 run --mysql_shell
check "MySQL Shell fails: failure metrics, lock released" 1 "MySQL Shell Backup Failed!" '[ "$(metric node_mysql_backup_status)" = 1 ] && db_lock_released'
fresh; UPLOAD_HANG=1 run --mysql_shell
check "MySQL Shell: hung upload is stopped by the timeout" 1 "did not finish within 2s and was stopped"

echo "--- local backups and options"
fresh; cp "$T/textfile/mysql_backup_status.prom" "$T/status.before"
run --xtrabackup_local
check "--xtrabackup_local: backup only, no upload, metrics untouched" 0 "Local XtraBackup Finished Successfully" '[ "$(uploads)" = 0 ] && cmp -s "$T/status.before" "$T/textfile/mysql_backup_status.prom" && db_lock_released'
fresh; run --mysql_shell_local
check "--mysql_shell_local: backup only, no upload" 0 "Local MySQL Shell Backup Finished Successfully" '[ "$(uploads)" = 0 ]'
run;              check "no option is rejected" 1 "Exactly one argument is required"
run --full;       check "an unknown option is rejected" 1 "Invalid argument '--full'"
cat "$T/out_a" >> "$T/all_out"; cp "$T/all_out" "$T/out"; RC=-
check "no run printed a shell error" - "" '! grep -nE "unbound variable|Bad file descriptor|command not found|syntax error|ambiguous redirect" "$T/all_out"'

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
