#!/bin/bash

# Tests postgresql_backup_v1_aws.sh against a mocked PostgreSQL (psql, pg_dump, pg_dumpall), pgBackRest, runuser and AWS CLI, with the
# real gpg (the archive is really encrypted and decrypted). No PostgreSQL server, bucket or root needed. Needs gpg and jq.
#
# Run on Linux (WSL works):         bash postgresql_prod_backup_scripts/tests/test_postgresql_backup_v1.sh
# With GNU timeout where the default timeout is uutils (Ubuntu 25.10+, as on WSL Ubuntu 26.04):
#                                    TIMEOUT_BIN=gnutimeout bash postgresql_prod_backup_scripts/tests/test_postgresql_backup_v1.sh
#
# The script is copied with its paths pointed at a temporary directory, a 2 s upload timeout and a 3 s wait for the lock's answer.
# Each case checks the exit code and the output, plus a condition, and the run ends with a PASS/FAIL count.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../postgresql_backup_v1_aws.sh"
REAL_GPG=$(command -v gpg) || { echo "FAIL  gpg is needed for the tests"; exit 1; }
command -v jq >/dev/null || { echo "FAIL  jq is needed for the tests (as for the script): sudo apt install jq"; exit 1; }
T=$(mktemp -d /tmp/pgbackuptest.XXXX)
mkdir -p "$T/bin" "$T/backup" "$T/bucket" "$T/textfile" "$T/shm"
# The passphrase in the mocked pgBackRest configuration, with characters a shell would trip over:
PASS='Te st$Pa`ss"wo'"'"'rd;|&'
printf '[global]\nrepo1-type=s3\nrepo1-cipher-type=aes-256-cbc\nrepo1-cipher-pass=%s\n\n[test-stanza]\npg1-path=/var/lib/pgsql/17/data\n' "$PASS" > "$T/pgbackrest.conf"
printf '%s' "$PASS" > "$T/pass.txt"

# Hung uploads, lock holders and gpg agents leave processes behind; kill them at the end.
cleanup(){
    [ -f "$T/pids" ] && xargs -r kill -9 < "$T/pids" 2>/dev/null
    pkill -f "gpg-agent.*$T" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

bash -n "$SRC" || { echo "FAIL  syntax check of $SRC"; exit 1; }

sed -e "s|^BACKUP_DIR=.*|BACKUP_DIR=\"$T/backup\"|" \
    -e "s|^PG_BIN_DIR=.*|PG_BIN_DIR=\"$T/bin\"|" \
    -e "s|^PGBACKREST_STANZA=.*|PGBACKREST_STANZA=\"test-stanza\"|" \
    -e "s|^PGBACKREST_CONFIG=.*|PGBACKREST_CONFIG=\"$T/pgbackrest.conf\"|" \
    -e "s|^S3_BUCKET=.*|S3_BUCKET=\"s3://test-bucket/pg_dump\"|" \
    -e "s|mktemp -p /dev/shm|mktemp -p $T/shm|" \
    -e "s|mktemp -d -p /dev/shm|mktemp -d -p $T/shm|" \
    -e "s|^TEXTFILE_COLLECTOR_DIR=.*|TEXTFILE_COLLECTOR_DIR=\"$T/textfile/\"|" \
    -e "s|^LOCK_FILE=.*|LOCK_FILE=\"$T/run.lock\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/backup.log\"|" \
    -e 's|^UPLOAD_TIMEOUT=.*|UPLOAD_TIMEOUT="2s"|' \
    -e 's|--kill-after=1m|--kill-after=2s|' \
    -e 's|while \[ "\$WAITED" -lt 600 \]|while [ "$WAITED" -lt 30 ]|' \
    -e "s|^\( *\)timeout --kill-after|\1${TIMEOUT_BIN:-timeout} --kill-after|" "$SRC" > "$T/backup.sh"

REPLACED=$(grep -cE "^(BACKUP_DIR|PG_BIN_DIR|PGBACKREST_STANZA|PGBACKREST_CONFIG|S3_BUCKET|TEXTFILE_COLLECTOR_DIR|LOCK_FILE|LOG_FILE|UPLOAD_TIMEOUT)=" "$T/backup.sh")
[ "$REPLACED" -eq 9 ] && [ "$(grep -c "mktemp .*-p $T/shm" "$T/backup.sh")" -eq 2 ] && [ "$(grep -c -- "${TIMEOUT_BIN:-timeout} --kill-after=2s" "$T/backup.sh")" -eq 1 ] && grep -q 'while \[ "$WAITED" -lt 30 \]' "$T/backup.sh" || {
    echo "FAIL  could not point the script's settings at the test directory (did a variable name change?)"; exit 1; }
# The same script with another run lock file: two runs that the run lock cannot stop (as if started on two hosts):
sed "s|^LOCK_FILE=.*|LOCK_FILE=\"$T/other.lock\"|" "$T/backup.sh" > "$T/backup_otherlock.sh"
sed "s|^LOCK_FILE=.*|LOCK_FILE=\"/nonexistent/dir/run.lock\"|" "$T/backup.sh" > "$T/backup_badlock.sh"
echo "Testing $SRC with $(${TIMEOUT_BIN:-timeout} --version | head -n 1), $("$REAL_GPG" --version | head -n 1)"
echo


# Mock runuser: only "runuser -u postgres -- command ...", recorded, then the command runs as this user.
cat > "$T/bin/runuser" <<'EOF'
#!/bin/bash
echo "$*" >> "$T/runuser.args"
[ "$1 $2 $3" = "-u postgres --" ] || { echo "mock runuser: unexpected arguments: $*" >&2; exit 2; }
shift 3
exec "$@"
EOF

# Mock psql: with -c it answers the script's queries (PG_IN_RECOVERY, PG_DATABASES). Without -c it is a session reading statements
# from stdin, like the lock session. The advisory lock is the file $T/dblock holding the PID of the session that has it; a session that
# ends releases its lock, as in PostgreSQL. PSQL_CONNECT_ERROR fails the connection, LOCK_ANSWER replaces the answer, LOCK_NO_ANSWER never answers.
cat > "$T/bin/psql" <<'EOF'
#!/bin/bash
echo "$*" >> "$T/psql.args"
[ -n "${PSQL_CONNECT_ERROR:-}" ] && { echo 'psql: error: connection to server on socket "/run/postgresql/.s.PGSQL.5432" failed: No such file or directory' >&2; exit 2; }
query=""; while [ $# -gt 0 ]; do [ "$1" = -c ] && query="$2"; shift; done
if [ -n "$query" ]; then
    case "$query" in
        *pg_is_in_recovery*) echo "${PG_IN_RECOVERY:-f}";;
        *"FROM pg_database"*) printf '%b\n' "${PG_DATABASES:-postgres\nshop}";;
        *) echo "mock psql: unexpected query: $query" >&2; exit 1;;
    esac
    exit 0
fi
release(){ [ "$(cat "$T/dblock" 2>/dev/null)" = "$$" ] && rm -f "$T/dblock"; }
trap release EXIT
while IFS= read -r line; do
    case "$line" in
        *"pg_try_advisory_lock(hashtextextended('backup_running', 0))"*)
            [ -n "${LOCK_NO_ANSWER:-}" ] && continue
            [ -n "${LOCK_ANSWER:-}" ] && { echo "$LOCK_ANSWER"; continue; }
            holder=$(cat "$T/dblock" 2>/dev/null)
            if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then echo f; else echo $$ > "$T/dblock"; echo t; fi;;
    esac
done
EOF

# Mock pgbackrest: the repository is $T/repo, one line per backup: label, type, bytes added, database id. info prints it as pgBackRest's
# JSON (DB_ID is the current database id; PGBACKREST_INFO_FAIL fails it). backup records its arguments and whether the advisory lock
# is held, then adds a backup (PGBACKREST_SLEEP, PGBACKREST_FAIL; PGBACKREST_TYPE_OVERRIDE stores another type, as when pgBackRest
# turns an incremental into a full one).
cat > "$T/bin/pgbackrest" <<'EOF'
#!/bin/bash
case " $* " in
    *" info "*)
        echo "$*" >> "$T/pgbackrest_info.args"
        [ -n "${PGBACKREST_INFO_FAIL:-}" ] && { echo "ERROR: [039]: HTTP request failed with 403 (Forbidden)" >&2; exit 39; }
        printf '[{"name":"test-stanza","db":[{"id":1},{"id":%s}],"backup":[' "${DB_ID:-1}"
        sep=""
        while read -r label type delta dbid; do
            printf '%s{"label":"%s","type":"%s","database":{"id":%s},"info":{"repository":{"delta":%s}}}' "$sep" "$label" "$type" "$dbid" "$delta"; sep=","
        done < <(cat "$T/repo" 2>/dev/null)
        printf ']}]\n'
        exit 0;;
    *" backup "*)
        echo "$*" > "$T/pgbackrest.args"
        h=$(cat "$T/dblock" 2>/dev/null); { [ -n "$h" ] && kill -0 "$h" 2>/dev/null && echo held || echo free; } > "$T/lock_during_backup"
        touch "$T/pgbackrest.started"
        [ -n "${PGBACKREST_SLEEP:-}" ] && sleep "$PGBACKREST_SLEEP"
        [ -n "${PGBACKREST_FAIL:-}" ] && { echo "P00  ERROR: [082]: WAL segment 000000010000000000000007 was not archived before the 60000ms timeout" >&2; exit 82; }
        type=$(echo "$*" | sed -n 's/.*--type=\([a-z]*\).*/\1/p'); type="${PGBACKREST_TYPE_OVERRIDE:-$type}"
        n=$(( $(cat "$T/repo" 2>/dev/null | wc -l) + 1 ))
        echo "label-$n-$type $type $((n * 1000 + 7)) ${DB_ID:-1}" >> "$T/repo"
        echo "P00   INFO: backup command end: completed successfully"
        exit 0;;
esac
echo "mock pgbackrest: unexpected arguments: $*" >&2; exit 2
EOF

# Mock pg_dump: creates its directory-format folder (--file), records its arguments and whether the advisory lock is held.
# PG_DUMP_FAIL_DB fails the dump of that database.
cat > "$T/bin/pg_dump" <<'EOF'
#!/bin/bash
echo "$*" >> "$T/pg_dump.args"
h=$(cat "$T/dblock" 2>/dev/null); { [ -n "$h" ] && kill -0 "$h" 2>/dev/null && echo held || echo free; } > "$T/lock_during_backup"
for a in "$@"; do case "$a" in --file=*) dir="${a#*=}";; --dbname=*) db="${a#*=}";; esac; done
[ -n "${PG_DUMP_FAIL_DB:-}" ] && [ "$db" = "$PG_DUMP_FAIL_DB" ] && { echo "pg_dump: error: query failed: ERROR:  permission denied for table secret" >&2; exit 1; }
mkdir -p "$dir" && echo "toc of $db" > "$dir/toc.dat" && echo "rows of $db" > "$dir/3001.dat.zst"
EOF

# Mock pg_dumpall: writes the roles to --file. PG_DUMPALL_FAIL fails it.
cat > "$T/bin/pg_dumpall" <<'EOF'
#!/bin/bash
echo "$*" >> "$T/pg_dumpall.args"
[ -n "${PG_DUMPALL_FAIL:-}" ] && { echo "pg_dumpall: error: could not connect to database template1" >&2; exit 1; }
for a in "$@"; do case "$a" in --file=*) echo "CREATE ROLE shop_app;" > "${a#*=}";; esac; done
EOF

# gpg: the real one, behind a wrapper that records its arguments and the passphrase it was given. GPG_FAIL fails it.
cat > "$T/bin/gpg" <<EOF
#!/bin/bash
echo "\$*" >> "\$T/gpg.args"
prev=""; for a in "\$@"; do [ "\$prev" = --passphrase-file ] && cat "\$a" > "\$T/key_seen"; prev="\$a"; done
[ -n "\${GPG_FAIL:-}" ] && { cat > /dev/null; echo "gpg: symmetric encryption failed: Input/output error" >&2; exit 2; }
exec "$REAL_GPG" "\$@"
EOF

# Mock aws: s3 cp --no-progress SRC s3://DST, into $T/bucket. UPLOAD_FAIL fails it, UPLOAD_HANG hangs it, UPLOAD_HANG_HARD also ignores
# the stop signal. The hang runs in a child process, like the AWS CLI's own workers, to check that a survivor does not keep the run lock.
cat > "$T/bin/aws" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "s3 cp --no-progress" ] || { echo "mock aws: unexpected arguments: $*" >&2; exit 2; }
src="$4"; dst="$T/bucket/${5#s3://}"
[ -e "/proc/$$/fd/9" ] && echo yes > "$T/aws_has_fd9"
[ -n "${UPLOAD_FAIL:-}" ] && { echo "upload failed: $src to $5 An error occurred (AccessDenied) when calling the PutObject operation: Access Denied" >&2; exit 1; }
[ -n "${UPLOAD_HANG:-}" ] && { sleep 600 & echo $! >> "$T/pids"; wait; }
[ -n "${UPLOAD_HANG_HARD:-}" ] && { trap '' TERM; sleep 600 & echo $! >> "$T/pids"; wait; }
mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; echo "upload: $src to $5"
EOF

# Mock which: HIDE_AWS makes the AWS CLI look not installed. Hiding it this way, not by removing the mock, keeps a real AWS CLI
# elsewhere in PATH from being found and run against a real bucket:
REAL_WHICH=$(command -v which)
printf '#!/bin/bash\n[ -n "${HIDE_AWS:-}" ] && [ "$1" = aws ] && exit 1\nexec %s "$@"\n' "$REAL_WHICH" > "$T/bin/which"
printf '#!/bin/bash\necho "$*" >> "$T/chown.args"\n' > "$T/bin/chown"
printf '#!/bin/bash\necho pg-test-src\n' > "$T/bin/hostname"
chmod +x "$T"/bin/*
export T PATH="$T/bin:$PATH"


# run SCRIPT OPTION: one run; its output (without colors) goes to $T/out, its exit code to RC
# The output goes through tee (the log), which can finish a moment after the script, hence the short wait:
run_script(){ local s="$1"; shift; bash "$s" "$@" > "$T/out" 2>&1; RC=$?; sleep 0.3; sed -i 's/\x1b\[[0-9;]*m//g' "$T/out"; cat "$T/out" >> "$T/all_out"; }
run(){ run_script "$T/backup.sh" "$@"; }
# fresh: empty backup folder, bucket and records of the last run (metrics and the repository stay)
fresh(){ rm -rf "$T"/backup/* "$T"/bucket/* "$T/pgbackrest.args" "$T/pgbackrest.started" "$T/lock_during_backup" "$T/aws_has_fd9" "$T/gpg.args" "$T/key_seen" "$T/pg_dump.args" "$T/pg_dumpall.args" "$T"/shm/*; }

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

metric(){ awk -v m="$1" 'index($0, m "{") == 1 {v=$2} END {print v}' "$T/textfile/postgresql_backup_status.prom" 2>/dev/null; }
inc_metric(){ awk -v m="$1" 'index($0, m "{") == 1 {v=$2} END {print v}' "$T/textfile/postgresql_incremental_backup_status.prom" 2>/dev/null; }
dump_metric(){ awk -v m="$1" 'index($0, m "{") == 1 {v=$2} END {print v}' "$T/textfile/postgresql_logical_backup_status.prom" 2>/dev/null; }
last_delta(){ tail -n 1 "$T/repo" | awk '{print $3}'; }
no_key_left(){ [ -z "$(ls -A "$T/shm")" ]; }
no_agent_left(){ for _ in $(seq 20); do pgrep -f "gpg-agent.*$T/shm" >/dev/null || return 0; sleep 0.1; done; return 1; }
db_lock_held(){ local h; h=$(cat "$T/dblock" 2>/dev/null); [ -n "$h" ] && kill -0 "$h" 2>/dev/null; }
# The lock session ends a moment after the script closes its input:
db_lock_released(){ for _ in $(seq 30); do db_lock_held || return 0; sleep 0.1; done; return 1; }
wait_for(){ for _ in $(seq 50); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
uploads(){ find "$T/bucket" -type f | wc -l; }
archive(){ find "$T/bucket" "$T/backup" -name 'pg-dump-*.tar.gpg' | head -n 1; }
# decrypt ARCHIVE: the archive's contents with the real gpg and the passphrase, as a restore would (in its own gpg folder):
decrypt(){ local h; h=$(mktemp -d "$T/gpgh.XXXX"); "$REAL_GPG" --homedir "$h" --batch --pinentry-mode loopback --passphrase-file "$T/pass.txt" --decrypt "$1" 2>/dev/null; local rc=$?; gpgconf --homedir "$h" --kill gpg-agent 2>/dev/null; rm -rf "$h"; return $rc; }


echo "--- pgbackrest (full)"
fresh; run --pgbackrest
check "full backup succeeds, with its metrics and age" 0 "Saved Success Metrics for pgBackRest Full Backup" '[ "$(metric node_postgresql_backup_status)" = 0 ] && grep -q "^node_postgresql_last_successful_backup_date{instance=\"pg-test-src\"}" "$T/textfile/postgresql_backup_age.prom"'
check "pgBackRest runs as postgres, full, on the stanza" - "" 'grep -q -- "--stanza=test-stanza --type=full backup" "$T/pgbackrest.args" && grep -q "^-u postgres -- pgbackrest --stanza=test-stanza --type=full backup" "$T/runuser.args"'
check "the backup ran while the advisory lock was held" - "Lock acquired successfully" '[ "$(cat "$T/lock_during_backup")" = held ]'
check "the advisory lock is released after the backup" - "has been released" 'db_lock_released'
check "the lock session: as postgres, in BACKUP_LOCK_DATABASE, named postgresql_backup_lock" - "" 'grep -q "dbname=shop application_name=postgresql_backup_lock" "$T/psql.args"'
check "the size metric is what pgBackRest added to its repository" - "bytes added" '[ "$(metric node_postgresql_backup_size_bytes)" = "$(last_delta)" ] && [ "$(metric node_postgresql_backup_size_bytes)" -gt 0 ]'
check "no transfer metrics for pgBackRest, and each metric once" - "" '! grep -q transfer "$T/textfile/postgresql_backup_status.prom" && [ -z "$(awk "{print \$1}" "$T/textfile/postgresql_backup_status.prom" | sort | uniq -d)" ]'
cp "$T/textfile/postgresql_backup_age.prom" "$T/age.before"
fresh; PGBACKREST_FAIL=1 run --pgbackrest
check "full backup fails: failure metrics, no size, the age stays, lock released" 1 "pgBackRest Full Backup failed." '[ "$(metric node_postgresql_backup_status)" = 1 ] && [ -z "$(metric node_postgresql_backup_size_bytes)" ] && cmp -s "$T/age.before" "$T/textfile/postgresql_backup_age.prom" && db_lock_released'
fresh; run --pgbackrest

echo "--- pgbackrest_incremental (the chain)"
mv "$T/repo" "$T/repo.saved"
fresh; run --pgbackrest_incremental
check "no full backup: the incremental fails and says to take a full backup" 1 "No full backup in the repository" '[ ! -e "$T/pgbackrest.args" ] && [ "$(inc_metric node_postgresql_incremental_backup_status)" = 1 ]'
echo "label-old-full full 5000 1" > "$T/repo"
fresh; DB_ID=2 run --pgbackrest_incremental
check "only a full of an older PostgreSQL version (before an upgrade): the incremental fails" 1 "No full backup in the repository" '[ ! -e "$T/pgbackrest.args" ]'
mv "$T/repo.saved" "$T/repo"
cp "$T/textfile/postgresql_backup_status.prom" "$T/full_status.before"; cp "$T/textfile/postgresql_backup_age.prom" "$T/full_age.before"
fresh; run --pgbackrest_incremental
check "incremental after a full: --type=incr, its own metrics and age" 0 "Saved Success Metrics for pgBackRest Incremental Backup" 'grep -q -- "--type=incr backup" "$T/pgbackrest.args" && [ "$(inc_metric node_postgresql_incremental_backup_status)" = 0 ] && grep -q "^node_postgresql_last_successful_incremental_backup_date" "$T/textfile/postgresql_incremental_backup_age.prom"'
check "the incremental's size is its own, and the full backup's metrics stay as they were" - "" '[ "$(inc_metric node_postgresql_incremental_backup_size_bytes)" = "$(last_delta)" ] && cmp -s "$T/full_status.before" "$T/textfile/postgresql_backup_status.prom" && cmp -s "$T/full_age.before" "$T/textfile/postgresql_backup_age.prom"'
fresh; PGBACKREST_TYPE_OVERRIDE=full run --pgbackrest_incremental
check "pgBackRest took another type than asked: a warning" 0 "newest backup is of type 'full', not 'incr'"
fresh; PGBACKREST_INFO_FAIL=1 run --pgbackrest_incremental
check "repository not readable: the incremental fails before taking the lock" 1 "Unable to read pgBackRest's repository" '[ ! -e "$T/pgbackrest.args" ] && [ "$(inc_metric node_postgresql_incremental_backup_status)" = 1 ] && ! db_lock_held'
fresh; PGBACKREST_FAIL=1 run --pgbackrest_incremental
check "incremental fails: failure metrics, lock released" 1 "pgBackRest Incremental Backup failed." '[ "$(inc_metric node_postgresql_incremental_backup_status)" = 1 ] && db_lock_released'

echo "--- the advisory lock"
fresh; sleep 600 & APP=$!; echo $APP >> "$T/pids"; echo $APP > "$T/dblock"
run --pgbackrest
check "lock held by an application job: the backup does not start" 1 "is held by another session" '[ ! -e "$T/pgbackrest.args" ] && [ "$(metric node_postgresql_backup_status)" = 1 ]'
check "the application keeps its lock" - "" '[ "$(cat "$T/dblock")" = "$APP" ]'
fresh; run --pg_dump
check "lock held by an application job: no pg_dump either" 1 "is held by another session" '[ ! -e "$T/pg_dump.args" ] && [ "$(dump_metric node_postgresql_logical_backup_status)" = 1 ] && no_key_left'
kill $APP; rm -f "$T/dblock"

fresh; PSQL_CONNECT_ERROR=1 run --pgbackrest
check "PostgreSQL down: fails with a message, the script does not die" 1 "no answer from PostgreSQL to pg_try_advisory_lock" 'grep -q "Saved Failure Metrics for pgBackRest Full Backup" "$T/out" && [ ! -e "$T/pgbackrest.args" ]'
fresh; LOCK_ANSWER=NULL run --pgbackrest
check "an unexpected answer: the backup does not start" 1 "got: 'NULL'" '[ ! -e "$T/pgbackrest.args" ]'
fresh; LOCK_NO_ANSWER=1 run --pgbackrest
check "no answer: fails after the wait" 1 "no answer from PostgreSQL to pg_try_advisory_lock" '[ ! -e "$T/pgbackrest.args" ] && db_lock_released'

fresh; PGBACKREST_SLEEP=3 bash "$T/backup_otherlock.sh" --pgbackrest > "$T/out_a" 2>&1 & A=$!
wait_for "$T/pgbackrest.started"; run --pgbackrest
check "two backups that the run lock cannot stop: only one gets the advisory lock" 1 "is held by another session" ''
wait $A; RC=$?; sleep 0.3; cp "$T/out_a" "$T/out"
check "the other backup finishes normally" 0 "Saved Success Metrics for pgBackRest Full Backup" 'db_lock_released'

fresh; PGBACKREST_SLEEP=3 bash "$T/backup.sh" --pgbackrest > "$T/out" 2>&1 & S=$!
wait_for "$T/pgbackrest.started"; kill -9 $S; wait $S 2>/dev/null; sleep 0.5; RC=-
check "script killed (kill -9): the advisory lock stays held while pgBackRest runs" - "" 'db_lock_held'
run --pg_dump_local
check "script killed: the run lock stays held while pgBackRest runs" 1 "Another backup is still running" ''
check "script killed: the advisory lock is released when pgBackRest ends" - "" 'for _ in $(seq 60); do db_lock_held || break; sleep 0.1; done; ! db_lock_held'
flock -w 10 "$T/run.lock" true  # the orphaned pgbackrest still holds the run lock for a moment

echo "--- the run lock (flock)"
fresh; PGBACKREST_SLEEP=2 bash "$T/backup.sh" --pgbackrest > "$T/out_a" 2>&1 & A=$!
wait_for "$T/pgbackrest.started"; BEFORE=$(cat "$T/textfile/postgresql_backup_status.prom")
run --pgbackrest
check "second run while one is running: refused, metrics untouched" 1 "Another backup is still running" '[ "$(cat "$T/textfile/postgresql_backup_status.prom")" = "$BEFORE" ]'
wait $A; RC=$?; sleep 0.3; cp "$T/out_a" "$T/out"
check "the first run finishes normally" 0 "Saved Success Metrics for pgBackRest Full Backup"
run_script "$T/backup_badlock.sh" --pgbackrest
check "run lock file cannot be opened: the run fails" 1 "Unable to open the lock file"
( exec 9> "$T/run.lock"; flock 9; sleep 3 ) & H=$!; sleep 0.5
run --help;          check "--help works while a backup runs" 0 "Available Backup Options"
run --pg_dump_local; check "local backups are refused while a backup runs" 1 "Another backup is still running"
wait $H

echo "--- replicas"
for OPT in --pgbackrest --pgbackrest_incremental --pg_dump; do
    fresh; cp -r "$T/textfile" "$T/textfile.before"
    PG_IN_RECOVERY=t run $OPT
    check "on a replica, $OPT does nothing: exit 0, no backup, metrics untouched" 0 "This server is a replica" '[ ! -e "$T/pgbackrest.args" ] && [ ! -e "$T/pg_dump.args" ] && diff -r "$T/textfile.before" "$T/textfile" >/dev/null && ! db_lock_held'
    rm -rf "$T/textfile.before"
done

echo "--- pg_dump"
fresh
mkdir -p "$T/backup/pg-dump-old" "$T/backup/pg-dump-recent"; touch -d "2 days ago" "$T/backup/pg-dump-old"; touch -d "3 hours ago" "$T/backup/pg-dump-recent"
touch -d "4 days ago" "$T/backup/pg-dump-old.tar.gpg"; touch -d "2 days ago" "$T/backup/pg-dump-recent.tar.gpg"
cp "$T/textfile/postgresql_backup_status.prom" "$T/full_status.before"
run --pg_dump
check "pg_dump backup and upload succeed" 0 "Saved Successful Transfer Metrics for pg_dump Backup" '[ "$(find "$T/bucket" -name "pg-dump-*.tar.gpg" | wc -l)" = 1 ] && [ "$(dump_metric node_postgresql_logical_backup_status)" = 0 ] && [ "$(dump_metric node_postgresql_logical_backup_transfer_status)" = 0 ] && grep -q "^node_postgresql_last_successful_logical_backup_date" "$T/textfile/postgresql_logical_backup_age.prom"'
check "the dump ran while the advisory lock was held, and released it" - "" '[ "$(cat "$T/lock_during_backup")" = held ] && db_lock_released'
check "every database is dumped, as postgres, in directory format with jobs and zstd, plus the roles" - "" '[ "$(grep -c -- "--format=directory --jobs=4 --compress=zstd" "$T/pg_dump.args")" = 2 ] && grep -q -- "--dbname=postgres" "$T/pg_dump.args" && grep -q -- "--dbname=shop" "$T/pg_dump.args" && grep -q -- "--globals-only" "$T/pg_dumpall.args" && grep -q "^-u postgres -- $T/bin/pg_dump " "$T/runuser.args" && grep -q "^postgres:postgres $T/backup/pg-dump-" "$T/chown.args"'
check "the archive decrypts with the passphrase into the dump folder: globals.sql and a folder per database" - "" 'decrypt "$(archive)" | tar -t > "$T/listing" && grep -q "^pg-dump-[0-9-]*/globals.sql$" "$T/listing" && grep -q "^pg-dump-[0-9-]*/shop/toc.dat$" "$T/listing" && grep -q "^pg-dump-[0-9-]*/postgres/toc.dat$" "$T/listing" && ! grep -qv "^pg-dump-" "$T/listing"'
check "gpg: AES256, no second compression, no passphrase cache, its own folder on the RAM disk" - "" 'grep -q -- "--homedir $T/shm/postgresql_backup_gnupg\..* --batch --yes --pinentry-mode loopback --passphrase-file $T/shm/postgresql_backup_key\..* --no-symkey-cache --symmetric --cipher-algo AES256 --compress-algo none" "$T/gpg.args"'
check "the passphrase comes from pgbackrest.conf, exactly, and is never on a command line or in the log" - "Passphrase read from" '[ "$(cat "$T/key_seen")" = "$PASS" ] && ! grep -qF -- "$PASS" "$T/gpg.args" "$T/out" "$T/backup.log" "$T/runuser.args"'
check "the passphrase file is gone from the RAM disk, and gpg's agent is stopped" - "" 'no_key_left && no_agent_left'
check "the size metric is the size of the archive" - "" '[ "$(dump_metric node_postgresql_logical_backup_size_bytes)" = "$(stat -c %s "$(find "$T/bucket" -name "pg-dump-*.tar.gpg")")" ]'
check "the full backup metrics stay as they were" - "" 'cmp -s "$T/full_status.before" "$T/textfile/postgresql_backup_status.prom"'
check "aws does not inherit the run lock (fd 9)" - "" '[ ! -e "$T/aws_has_fd9" ]'
check "cleanup: dump folders older than a day and archives older than 3 days go, newer ones stay" - "" '[ ! -e "$T/backup/pg-dump-old" ] && [ -e "$T/backup/pg-dump-recent" ] && [ ! -e "$T/backup/pg-dump-old.tar.gpg" ] && [ -e "$T/backup/pg-dump-recent.tar.gpg" ]'
check "the unencrypted dump folder and the archive of this run stay in /backup" - "" '[ "$(find "$T/backup" -maxdepth 1 -type d -name "pg-dump-2*" | wc -l)" = 1 ] && [ "$(find "$T/backup" -maxdepth 1 -name "pg-dump-2*.tar.gpg" | wc -l)" = 1 ]'
check "a wrong passphrase cannot decrypt the archive" - "" 'printf wrong > "$T/pass.wrong"; h=$(mktemp -d "$T/gpgh.XXXX"); ! "$REAL_GPG" --homedir "$h" --batch --pinentry-mode loopback --passphrase-file "$T/pass.wrong" --decrypt "$(archive)" > /dev/null 2>&1; r=$?; gpgconf --homedir "$h" --kill gpg-agent 2>/dev/null; [ $r -eq 0 ]'

fresh; PG_DUMP_FAIL_DB=postgres run --pg_dump
check "one database fails: the backup fails (transfer too), the others are still dumped, nothing uploaded" 1 "pg_dump Backup Failed!" '[ "$(dump_metric node_postgresql_logical_backup_status)" = 1 ] && [ "$(dump_metric node_postgresql_logical_backup_transfer_status)" = 1 ] && grep -q -- "--dbname=shop" "$T/pg_dump.args" && [ "$(uploads)" = 0 ] && db_lock_released && no_key_left && no_agent_left'
fresh; PG_DUMPALL_FAIL=1 run --pg_dump
check "pg_dumpall (the roles) fails: the backup fails" 1 "pg_dump Backup Failed!" '[ "$(uploads)" = 0 ] && db_lock_released && no_key_left'
fresh; GPG_FAIL=1 run --pg_dump
check "gpg fails: failure metrics, nothing uploaded, no passphrase left" 1 "Backup Folder Archive Failed!" '[ "$(dump_metric node_postgresql_logical_backup_status)" = 1 ] && [ "$(uploads)" = 0 ] && db_lock_released && no_key_left && no_agent_left'
cp "$T/pgbackrest.conf" "$T/pgbackrest.conf.saved"; grep -v cipher-pass "$T/pgbackrest.conf.saved" > "$T/pgbackrest.conf"
fresh; run --pg_dump
check "no repo1-cipher-pass in pgbackrest.conf: nothing is dumped, lock released" 1 "No repo1-cipher-pass in" '[ ! -e "$T/pg_dump.args" ] && [ "$(dump_metric node_postgresql_logical_backup_status)" = 1 ] && db_lock_released && no_key_left'
rm -f "$T/pgbackrest.conf"
fresh; run --pg_dump
check "pgbackrest.conf not readable: nothing is dumped" 1 "Unable to read $T/pgbackrest.conf" '[ ! -e "$T/pg_dump.args" ] && no_key_left'
mv "$T/pgbackrest.conf.saved" "$T/pgbackrest.conf"
fresh; run --pgbackrest
check "pgBackRest does not need the passphrase from the script" 0 "Saved Success Metrics for pgBackRest Full Backup" '[ ! -e "$T/gpg.args" ]'

echo "--- uploads"
fresh; UPLOAD_FAIL=1 run --pg_dump
check "failed upload: transfer failure metrics, the archive stays in /backup" 1 "Transfer to S3 Bucket Failed! (pg_dump)" '[ "$(dump_metric node_postgresql_logical_backup_status)" = 0 ] && [ "$(dump_metric node_postgresql_logical_backup_transfer_status)" = 1 ] && [ -n "$(archive)" ]'
fresh; UPLOAD_HANG=1 run --pg_dump
check "hung upload is stopped by the timeout" 1 "did not finish within 2s and was stopped" '[ "$(dump_metric node_postgresql_logical_backup_transfer_status)" = 1 ]'
fresh; UPLOAD_HANG_HARD=1 run --pg_dump
check "hung upload that ignores the stop signal is killed" 1 "did not finish within 2s and was stopped"
fresh; run --pg_dump
check "next run is not blocked by a leftover upload process" 0 "Saved Successful Transfer Metrics for pg_dump Backup"

echo "--- local backups and options"
fresh; cp "$T/textfile/postgresql_logical_backup_status.prom" "$T/status.before"
run --pg_dump_local
check "--pg_dump_local: dump and archive only, no upload, metrics untouched" 0 "Local pg_dump Backup Finished Successfully" '[ "$(uploads)" = 0 ] && [ -n "$(archive)" ] && cmp -s "$T/status.before" "$T/textfile/postgresql_logical_backup_status.prom" && db_lock_released && no_key_left'
run;              check "no option is rejected" 1 "Exactly one argument is required (got 0)"
fresh; run --pgbackrest --pg_dump
check "two options are rejected, nothing runs" 1 "Exactly one argument is required (got 2)" '[ ! -e "$T/pgbackrest.args" ] && [ "$(uploads)" = 0 ]'
run --xtrabackup; check "an unknown option is rejected" 1 "Invalid argument '--xtrabackup'"
cat "$T/out_a" >> "$T/all_out"; cp "$T/all_out" "$T/out"; RC=-
check "no run printed a shell error" - "" '! grep -nE "unbound variable|Bad file descriptor|command not found|syntax error|ambiguous redirect|integer expression expected" "$T/all_out"'

echo "--- the log"
L="$T/backup.log"
check "every backup run is logged, with its header line" - "" '[ "$(grep -c "| pg-test-src | --" "$L")" -ge 20 ] && grep -q "| pg-test-src | --pg_dump_local =====" "$L"'
check "the log keeps earlier runs, refused ones too, with their colors" - "" 'grep -q "Saved Successful Transfer Metrics for pg_dump Backup" "$L" && grep -q "Another backup is still running" "$L" && grep -q $'"'"'\e\['"'"' "$L"'
check "--help, unknown and missing options are not logged" - "" '! grep -qE "\| pg-test-src \| (--help|--xtrabackup|) =====" "$L"'
fresh; HIDE_AWS=1 run --pg_dump
check "AWS CLI missing: the error reaches the log, the upload fails" 1 "AWS CLI is not installed" 'grep -q "AWS CLI is not installed" "$L" && [ "$(dump_metric node_postgresql_logical_backup_transfer_status)" = 1 ] && [ "$(uploads)" = 0 ]'
fresh; HIDE_AWS=1 run --pgbackrest
check "AWS CLI missing: pgBackRest backups do not need it" 0 "Saved Success Metrics for pgBackRest Full Backup" '! grep -q "AWS CLI is not installed" "$T/out"'

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
