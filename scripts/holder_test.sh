#!/usr/bin/env bash
# SIGTERM must reach the holder trap without waiting out sleep 3600.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB="$ROOT/tests/storage/holder.nomad.hcl"

PASS=0
FAIL=0

check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL ${name}" >&2
    FAIL=$((FAIL + 1))
  fi
}

awk 'f && /^HOLDEREOF$/ { exit } f; /<<HOLDEREOF$/ { f = 1 }' "$JOB" | sed 's/\$\${/${/g' > /tmp/hold.sh
chmod 755 /tmp/hold.sh

DATA=$(mktemp -d)
trap 'rm -rf "$DATA"' EXIT
out=$(mktemp)

start=$(date +%s)
NODE_NAME=pinode2 SHUTDOWN_DELAY=2 DATA_DIR="$DATA" /bin/sh /tmp/hold.sh >"$out" 2>"$out.err" &
pid=$!
# If the trap is stuck behind sleep 3600, this kills the test instead of waiting.
( sleep 8; kill -KILL "$pid" 2>/dev/null ) &
watchdog=$!
sleep 0.4
kill -TERM "$pid"
set +e
wait "$pid"
rc=$?
set -e
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))

check "holder exits on TERM" test "$rc" -eq 0
check "holder trap ran" grep -q 'shutdown trap 2' "$out"
check "holder wrote the marker" test -s "$DATA/marker"
# The 2s trap, not an hour of foreground sleep. 8s is the watchdog.
check "holder shutdown delay is the trap" test "$elapsed" -ge 2 -a "$elapsed" -le 7

rm -f /tmp/hold.sh "$out" "$out.err"
echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
