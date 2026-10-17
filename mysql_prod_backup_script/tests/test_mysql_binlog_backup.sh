#!/bin/bash

# Tests mysql_binlog_backup_v2.sh against a mocked MySQL and gcloud. No MySQL server, bucket or root needed.
#
# Run on Linux (WSL works):         bash mysql_prod_backup_script/tests/test_mysql_binlog_backup.sh
# With GNU timeout where the default timeout is uutils (Ubuntu 25.10+, as on WSL Ubuntu 26.04):
#                                    TIMEOUT_BIN=gnutimeout bash mysql_prod_backup_script/tests/test_mysql_binlog_backup.sh
#
# The script is copied with its paths pointed at a temporary directory and a 2 s upload timeout.
# Each case checks the exit code, the tracking file and the output, and the run ends with a PASS/FAIL count.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../mysql_binlog_backup_v2.sh"
T=$(mktemp -d /tmp/binlogtest.XXXX)
TRACK="$T/state/last_binlog_backup.txt"
SERVER="test-server"
mkdir -p "$T/bin" "$T/datadir" "$T/bucket" "$T/textfile" "$T/state"

# Hung uploads leave sleep processes behind with uutils timeout; kill them at the end.
cleanup(){
    [ -f "$T/hung.pids" ] && xargs -r kill -9 < "$T/hung.pids" 2>/dev/null
    chmod -R u+w "$T" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

bash -n "$SRC" || { echo "FAIL  syntax check of $SRC"; exit 1; }

sed -e "s|^DATA_DIR=.*|DATA_DIR=\"$T/datadir\"|" \
    -e "s|^LAST_BINLOG_BACKUP_FILE=.*|LAST_BINLOG_BACKUP_FILE=\"$TRACK\"|" \
    -e "s|^TEXTFILE_COLLECTOR_DIR=.*|TEXTFILE_COLLECTOR_DIR=\"$T/textfile/\"|" \
    -e "s|^LOCK_FILE=.*|LOCK_FILE=\"$T/lock\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/backup.log\"|" \
    -e "s|^SERVER_NAME=.*|SERVER_NAME=\"$SERVER\"|" \
    -e 's|^UPLOAD_TIMEOUT=.*|UPLOAD_TIMEOUT="2s"|' \
    -e 's|--kill-after=1m|--kill-after=2s|' \
    -e "s|^\( *\)timeout --kill-after|\1${TIMEOUT_BIN:-timeout} --kill-after|" "$SRC" > "$T/backup.sh"

REPLACED=$(grep -cE "^(DATA_DIR|LAST_BINLOG_BACKUP_FILE|TEXTFILE_COLLECTOR_DIR|LOCK_FILE|LOG_FILE|SERVER_NAME|UPLOAD_TIMEOUT)=" "$T/backup.sh")
grep -q -- "${TIMEOUT_BIN:-timeout} --kill-after=2s" "$T/backup.sh" && [ "$REPLACED" -eq 7 ] || {
    echo "FAIL  could not point the script's settings at the test directory (did a variable name change?)"; exit 1; }
echo "Testing $SRC with $(${TIMEOUT_BIN:-timeout} --version | head -n 1)"
echo


# Mock mysql: the server's binary logs are listed in $T/index and their files are in $T/datadir.
# MYSQL_CONNECT_ERROR / MYSQL_FLUSH_ERROR make it fail like a real server would.
cat > "$T/bin/mysql" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -e) shift; Q="$1";; esac; shift; done
[ -n "${MYSQL_CONNECT_ERROR:-}" ] && { echo "ERROR 2002 (HY000): Can't connect to local MySQL server through socket '/var/lib/mysql/mysql.sock' (2)" >&2; exit 1; }
case "$Q" in
  "SHOW BINARY LOGS;") while read -r f; do printf '%s\t100\tNo\n' "$f"; done < "$T/index";;
  "FLUSH BINARY LOGS;") [ -n "${MYSQL_FLUSH_ERROR:-}" ] && { echo "ERROR 1227 (42000) at line 1: Access denied; you need (at least one of) the RELOAD privilege(s) for this operation" >&2; exit 1; }
                        last=$(tail -n 1 "$T/index"); f=$(printf 'mysql-bin.%06d' $((10#${last##*.} + 1)))
                        echo "$f" >> "$T/index"; echo data > "$T/datadir/$f";;
  *) echo "mock mysql: unexpected query: $Q" >&2; exit 1;;
esac
EOF

# Mock gcloud: storage cp --if-generation-match=0 SRC gs://DST, into $T/bucket.
# FAIL_ON=<file> fails that upload, HANG_ON=<file> hangs it, HANG_HARD_ON=<file> hangs it and ignores the stop signal.
# The hang runs in a child process, like gcloud's own workers, to check that a survivor does not keep the lock.
cat > "$T/bin/gcloud" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "storage cp --if-generation-match=0" ] || { echo "mock gcloud: unexpected arguments: $*" >&2; exit 2; }
src="$4"; dst="$T/bucket/${5#gs://}"; name=$(basename "$src")
[ "${FAIL_ON:-}" = "$name" ] && { echo "ERROR: (gcloud.storage.cp) HTTPError 503: Service unavailable" >&2; exit 1; }
[ "${HANG_ON:-}" = "$name" ] && { sleep 600 & echo $! >> "$T/hung.pids"; wait; }
[ "${HANG_HARD_ON:-}" = "$name" ] && { trap '' TERM; sleep 600 & echo $! >> "$T/hung.pids"; wait; }
[ -f "$src" ] || { echo "ERROR: (gcloud.storage.cp) The following URLs matched no objects or files: $src" >&2; exit 1; }
[ -e "$dst" ] && { echo "ERROR: (gcloud.storage.cp) HTTPError 412: At least one of the pre-conditions you specified did not hold." >&2; exit 1; }
mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"
EOF
chmod +x "$T"/bin/*
export T PATH="$T/bin:$PATH"


# server FIRST LAST: the binary logs on the server
server(){
    rm -f "$T"/datadir/*; : > "$T/index"
    for n in $(seq "$1" "$2"); do
        f=$(printf 'mysql-bin.%06d' "$n"); echo "$f" >> "$T/index"; echo data > "$T/datadir/$f"
    done
}

# run OPTION...: one run of the script; its output (without colors) goes to $T/out, its exit code to RC
run(){
    bash "$T/backup.sh" "$@" > "$T/out" 2>&1; RC=$?
    sleep 0.3  # the log is written through tee, which can finish a moment after the script
    sed -i 's/\x1b\[[0-9;]*m//g' "$T/out"
}

PASSED=0; FAILED=0
# check NAME EXIT TRACKING [TEXT] [CONDITION]: TRACKING "-" skips the tracking file, CONDITION is a shell test
check(){
    local name="$1" want_rc="$2" want_track="$3" text="${4:-}" cond="${5:-}"
    local track; track=$(cat "$TRACK" 2>/dev/null || echo "(none)")
    local problems=""
    [ "$RC" = "$want_rc" ] || problems+=" exit $RC, expected $want_rc;"
    [ "$want_track" = "-" ] || [ "$track" = "$want_track" ] || problems+=" tracking '$track', expected '$want_track';"
    [ -z "$text" ] || grep -qF -- "$text" "$T/out" || problems+=" output lacks '$text';"
    [ -z "$cond" ] || eval "$cond" || problems+=" failed: $cond;"
    if [ -z "$problems" ]; then
        PASSED=$((PASSED + 1)); echo "PASS  $name"
    else
        FAILED=$((FAILED + 1)); echo "FAIL  $name:$problems"; sed 's/^/        /' "$T/out" | head -n 15
    fi
}

status_metric(){ awk '/^node_mysql_binlog_backup_status/ {print $2}' "$T/textfile/mysql_binlog_backup_status.prom" 2>/dev/null; }
objects(){ find "$T/bucket" -type f | wc -l; }
C=--continuous_binlog_backup


echo "--- starting a chain"
server 5 8
run $C;                                    check "no chain: the run fails without rotating the binlog" 1 "(none)" "No binlog chain to continue" '[ "$(tail -n 1 "$T/index")" = mysql-bin.000008 ] && [ "$(status_metric)" = 1 ]'
run --init_binlog_chain;                   check "init without a binary log is refused" 1 "(none)" "needs the binary log the chain starts with"
run --init_binlog_chain mysql-bin.000003;  check "init with a purged binary log is refused" 1 "(none)" "mysql-bin.000003 is not on the server"
run --init_binlog_chain mysql-bin.000005;  check "init mysql-bin.000005 records the one before it" 0 "mysql-bin.000004" "New binlog chain started with mysql-bin.000005"
run --init_binlog_chain mysql-bin.000006;  check "init while a chain exists is refused" 1 "mysql-bin.000004" "A binlog chain already exists"

echo "--- normal runs"
run $C;  check "first run uploads 000005 to 000008" 0 "mysql-bin.000008" "Saved Success Metrics" '[ "$(objects)" = 4 ] && [ "$(status_metric)" = 0 ]'
run $C;  check "next run uploads 000009 (numbers 08 and 09 are not read as octal)" 0 "mysql-bin.000009"
check "uploads go to <bucket>/<server>/<date>/" 0 - "" '[ "$(find "$T/bucket" -path "*/binlog_backups/$SERVER/$(date +%Y-%m-%d)/mysql-bin.*" | wc -l)" = 5 ]'

echo "--- upload failures"
FAIL_ON=mysql-bin.000010 run $C;      check "failed upload: run fails, tracking stays" 1 "mysql-bin.000009" "Error backing up binary log file: mysql-bin.000010" '[ "$(status_metric)" = 1 ]'
run $C;                               check "next run retries 000010 and continues, no gap" 0 "mysql-bin.000011"
HANG_ON=mysql-bin.000012 run $C;      check "hung upload is stopped by the timeout" 1 "mysql-bin.000011" "did not finish within 2s"
HANG_HARD_ON=mysql-bin.000012 run $C; check "hung upload that ignores the stop signal is killed" 1 "mysql-bin.000011" "did not finish within 2s"
run $C;                               check "next run is not blocked by a leftover process (lock not inherited)" 0 "mysql-bin.000014" "Saved Success Metrics"
cp "$TRACK" "$T/track.saved"; mkdir -p "$T/lockholder"
( exec 9> "$T/lock"; flock 9; sleep 3 ) & sleep 0.5
run $C;                               check "busy lock: the run skips with exit 0 and changes nothing" 0 "mysql-bin.000014" "still running, skipping this run" '[ "$(status_metric)" = 0 ]'
wait

echo "--- MySQL failures"
MYSQL_CONNECT_ERROR=1 run $C;  check "MySQL down: the run fails" 1 "mysql-bin.000014" "Unable to retrieve the list of binary log files" '[ "$(status_metric)" = 1 ]'
MYSQL_FLUSH_ERROR=1 run $C;    check "FLUSH BINARY LOGS refused: the run fails" 1 "mysql-bin.000014" "Unable to flush the MySQL binary logs"

echo "--- the chain"
server 20 21; run $C;                       check "gap: binlogs purged before upload stop the backup" 1 "mysql-bin.000014" "Gap in the binlog chain after mysql-bin.000014"
run $C;                                     check "gap: the next run still fails" 1 "mysql-bin.000014" "Take a new full backup now"
rm -f "$TRACK"; run --init_binlog_chain mysql-bin.000021; check "after a full backup: a new chain from 000021" 0 "mysql-bin.000020"
run $C;                                     check "the new chain uploads 000021 onward" 0 "mysql-bin.000023"
rm -f "$TRACK"; server 150 152; run --init_binlog_chain mysql-bin.000150
FAIL_ON=mysql-bin.000150 run $C;            check "first run of a new chain fails" 1 "mysql-bin.000149"
run $C;                                     check "the run after it reports no false gap" 0 "mysql-bin.000153"
: > "$TRACK"; server 160 161; run $C;       check "emptied tracking file is an error, not a new chain" 1 "" "does not hold a binary log file name"
echo mysql-bin.000161 > "$TRACK"; server 1 2; run $C; check "binlog numbering went backwards" 1 "mysql-bin.000161" "numbering went backwards"
if [ "$(id -u)" -ne 0 ]; then
    echo mysql-bin.000001 > "$TRACK"; server 1 3; chmod a-w "$T/state"; run $C; chmod u+w "$T/state"
    check "tracking file cannot be written: the old one stays intact" 1 "mysql-bin.000001" "Unable to write the tracking file" '! ls "$T/state" | grep -q tmp'
else
    echo "SKIP  tracking file cannot be written (needs a non-root user)"
fi

echo "--- options and log"
run --help;          check "--help explains which binary log to start from" 0 - "Which binary log to start the chain from"
run --binlog_backup; check "the old option --binlog_backup is rejected" 1 - "Invalid argument '--binlog_backup'"
run;                 check "no option is rejected" 1 - "An option is required"
check "every run is logged with its header and colors" 1 - "" '[ "$(grep -c "| $SERVER |" "$T/backup.log")" -ge 20 ] && grep -q $'"'"'\e\['"'"' "$T/backup.log" && ! grep -qF "| $SERVER | --help" "$T/backup.log"'

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
