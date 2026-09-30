#!/usr/bin/env bash
# Exercises reconcile decisions with a fake nomad. Does not contact a cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/reconcile-nomad.sh
source "$ROOT/scripts/reconcile-nomad.sh"

PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL ${name}" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local got="$1" want="$2"
  if [[ "$got" != "$want" ]]; then
    echo "got:  ${got}" >&2
    echo "want: ${want}" >&2
    return 1
  fi
}

assert_file_lacks() {
  local file="$1" needle="$2"
  ! grep -F -q -- "$needle" "$file"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls"
: >"$CALLS"

nomad() {
  printf '%s\n' "$*" >>"$CALLS"
  local joined="$*"
  if [[ "$joined" == *"-detach"* ]]; then
    echo "refusing -detach" >&2
    return 99
  fi
  if [[ "$joined" == *"var get"* || "$joined" == *"node drain"* || "$joined" == *"job stop"* || "$joined" == *"job delete"* ]]; then
    echo "refusing forbidden nomad command" >&2
    return 98
  fi

  case "$1 $2" in
    "job plan")
      local spec=""
      for arg in "$@"; do
        spec="$arg"
      done
      case "$spec" in
        *noop.nomad.hcl)
          printf '%s\n' 'Job: "noop"' '' 'Scheduler dry-run:' '- All tasks successfully allocated.' '' 'Job Modify Index: 4'
          return 0
          ;;
        *inplace.nomad.hcl)
          printf '%s\n' '+/- Job: "inplace"' '+/- Task Group: "web" (1 in-place update)' '  +/- Task: "web" (forces in-place update)' '' 'Scheduler dry-run:' '- All tasks successfully allocated.' '' 'Job Modify Index: 9'
          return 0
          ;;
        *replace.nomad.hcl)
          printf '%s\n' '+/- Job: "replace"' '+/- Meta[version]: "1" => "2"' '+/- Task Group: "web" (1 create/destroy update)' '  +/- Task: "web" (forces create/destroy update)' '    +/- Config {' '      +/- image: "app:1" => "app:2"' '        }' '' 'Scheduler dry-run:' '- All tasks successfully allocated.' '' 'Job Modify Index: 11'
          return 1
          ;;
        *planerr.nomad.hcl)
          echo "Error during plan: connection refused"
          return 255
          ;;
        *noindex.nomad.hcl)
          printf '%s\n' '+/- Job: "noindex"' '+/- Priority: "50" => "40"'
          return 0
          ;;
        *deployfail.nomad.hcl)
          printf '%s\n' '+/- Job: "deployfail"' '+/- Count: "1" => "2" (forces create)' '' 'Scheduler dry-run:' '- All tasks successfully allocated.' '' 'Job Modify Index: 15'
          return 1
          ;;
        *downgrade.nomad.hcl)
          printf '%s\n' '+/- Job: "downgrade"' '      +/- MemoryMB: "4096" => "2048"' '      +/- CPU: "1500" => "500"' '      +/- image: "bitcoin/bitcoin:31.1" => "bitcoin/bitcoin:30.2"' 'rpcauth=downgrade-secret' '' 'Scheduler dry-run:' '- All tasks successfully allocated.' '' 'Job Modify Index: 21'
          return 1
          ;;
        *okup.nomad.hcl)
          printf '%s\n' '+/- Job: "okup"' '      +/- image: "ghcr.io/getalby/hub:v1.21.4" => "ghcr.io/getalby/hub:v1.24.0"' '      +/- MemoryMB: "512" => "1024"' '' 'Scheduler dry-run:' '- All tasks successfully allocated.' '' 'Job Modify Index: 30'
          return 0
          ;;
        *)
          echo "unexpected plan spec $spec" >&2
          return 97
          ;;
      esac
      ;;
    "job run")
      local spec=""
      for arg in "$@"; do
        spec="$arg"
      done
      if [[ "$spec" == *deployfail.nomad.hcl ]]; then
        echo "Deployment failed"
        echo "rpcauth=super-secret-value"
        return 1
      fi
      echo "Deployment successful"
      return 0
      ;;
    "job status")
      cat <<'EOF'
Allocations
ID        Node ID   Task Group  Version  Desired  Status   Created  Modified
abc12345  node1     web         2        run      failed   1s ago   1s ago

Summary
EOF
      echo "password=hunter2"
      return 0
      ;;
    "alloc status")
      printf '%s\n' 'Task "web" is "failed"' 'authkey=should-not-leak'
      return 0
      ;;
    "alloc logs")
      if [[ "$*" == *"-stderr"* ]]; then
        echo "stderr token=abcd"
      else
        echo "stdout line"
        echo "secret=abcd"
      fi
      return 0
      ;;
    *)
      echo "unexpected nomad invocation: $*" >&2
      return 96
      ;;
  esac
}

write_job() {
  local rel="$1" body="$2"
  mkdir -p "$TMP/tree/$(dirname "$rel")"
  printf '%s\n' "$body" >"$TMP/tree/$rel"
}

cd "$ROOT"
check "bitcoin namespace from file" assert_eq "$(namespace_for nomad_jobs/bitcoin/bitcoin-stack.nomad.hcl)" "bitcoin"
check "observability namespace from file" assert_eq "$(namespace_for nomad_jobs/observability/prometheus.nomad.hcl)" "default"
check "node-exporter namespace from file" assert_eq "$(namespace_for nomad_jobs/observability/node-exporter.nomad.hcl)" "default"
check "plugins directory default" assert_eq "$(namespace_for nomad_jobs/plugins/nfs-nodes.nomad.hcl)" "default"
check "plugins controller directory default" assert_eq "$(namespace_for nomad_jobs/plugins/nfs-controller.nomad.hcl)" "default"

write_job "nomad_jobs/bitcoin/override.nomad.hcl" 'job "override" {
  namespace = "other"
  group "g" {
    task "t" {
      driver = "docker"
    }
  }
}'
write_job "nomad_jobs/plugins/commented.nomad.hcl" 'job "commented" {
  # namespace = "bitcoin"
  group "g" {}
}'
cd "$TMP/tree"
check "file namespace wins" assert_eq "$(namespace_for nomad_jobs/bitcoin/override.nomad.hcl)" "other"
check "commented namespace ignored" assert_eq "$(namespace_for nomad_jobs/plugins/commented.nomad.hcl)" "default"

plan_of() {
  local rc="$1" text="$2" f
  f="$(mktemp)"
  printf '%s\n' "$text" >"$f"
  plan_decision "$rc" "$f"
  rm -f "$f"
}

check "exit 0 empty diff is noop" assert_eq "$(plan_of 0 $'Job: "x"\n\nScheduler dry-run:\n- All tasks successfully allocated.\n\nJob Modify Index: 3')" "noop"
check "exit 0 in-place diff applies" assert_eq "$(plan_of 0 $'+/- Job: "x"\n+/- Task Group: "g" (1 in-place update)\n\nScheduler dry-run:\n- All tasks successfully allocated.\n\nJob Modify Index: 8')" "apply 8"
check "exit 1 is changes and applies" assert_eq "$(plan_of 1 $'+/- Job: "x"\n+/- Task Group: "g" (1 create/destroy update)\n\nScheduler dry-run:\n- All tasks successfully allocated.\n\nJob Modify Index: 2')" "apply 2"
check "exit 1 without diff text still applies" assert_eq "$(plan_of 1 $'Scheduler dry-run:\n- All tasks successfully allocated.\n\nJob Modify Index: 6')" "apply 6"
check "exit 255 is error" assert_eq "$(plan_of 255 $'Error during plan')" "error plan-exit-255"
check "missing index does not apply" assert_eq "$(plan_of 0 $'+/- Job: "x"\n+/- Priority: "1" => "2"')" "error missing-check-index"
check "memory downgrade is refused" assert_eq "$(plan_of 1 $'+/- MemoryMB: "4096" => "2048"\n\nJob Modify Index: 5')" "refuse"
check "cpu downgrade is refused" assert_eq "$(plan_of 0 $'+/- CPU: "1500" => "500"\n\nJob Modify Index: 5')" "refuse"
check "memory max downgrade is refused" assert_eq "$(plan_of 0 $'+/- MemoryMaxMB: "8192" => "4096"\n\nJob Modify Index: 5')" "refuse"
check "memory upgrade still applies" assert_eq "$(plan_of 0 $'+/- MemoryMB: "2048" => "4096"\n\nJob Modify Index: 5')" "apply 5"
check "equal specs still apply" assert_eq "$(plan_of 0 $'+/- CPU: "1500" => "1500"\n+/- MemoryMB: "4096" => "4096"\n+/- image: "app:1.2.0" => "app:1.2.0"\n+/- Meta[version]: "1" => "2"\n\nJob Modify Index: 4')" "apply 4"
check "image downgrade is refused" assert_eq "$(plan_of 1 $'+/- image: "bitcoin/bitcoin:31.1" => "bitcoin/bitcoin:30.2"\n\nJob Modify Index: 5')" "refuse"
check "v-prefixed image downgrade is refused" assert_eq "$(plan_of 0 $'+/- image: "getumbrel/electrs:v0.11.1" => "getumbrel/electrs:v0.10.10"\n\nJob Modify Index: 5')" "refuse"
check "shorter dotted downgrade is refused" assert_eq "$(plan_of 0 $'+/- image: "app:1.2.1" => "app:1.2"\n\nJob Modify Index: 5')" "refuse"
check "numeric minor downgrade is refused" assert_eq "$(plan_of 0 $'+/- image: "app:1.10" => "app:1.9"\n\nJob Modify Index: 5')" "refuse"
check "registry port tag downgrade is refused" assert_eq "$(plan_of 0 $'+/- image: "localhost:5000/app:2.1" => "localhost:5000/app:1.0"\n\nJob Modify Index: 5')" "refuse"
check "image upgrade still applies" assert_eq "$(plan_of 0 $'+/- image: "ghcr.io/getalby/hub:v1.21.4" => "ghcr.io/getalby/hub:v1.24.0"\n\nJob Modify Index: 5')" "apply 5"
check "leading v equal to pin still applies" assert_eq "$(plan_of 0 $'+/- image: "app:v1.2.0" => "app:1.2.0"\n\nJob Modify Index: 5')" "apply 5"
check "latest to pin is not a downgrade" assert_eq "$(plan_of 0 $'+/- image: "app:latest" => "app:1.2.3"\n\nJob Modify Index: 5')" "apply 5"
check "pin to latest is not a downgrade" assert_eq "$(plan_of 0 $'+/- image: "app:1.2.3" => "app:latest"\n\nJob Modify Index: 5')" "apply 5"
check "image downgrade with memory upgrade is refused" assert_eq "$(plan_of 0 $'+/- image: "app:2.0" => "app:1.0"\n+/- MemoryMB: "256" => "512"\n\nJob Modify Index: 5')" "refuse"

rm -rf "$TMP/tree/nomad_jobs"
: >"$CALLS"
write_job "nomad_jobs/observability/noop.nomad.hcl" 'job "noop" { group "g" {} }'
write_job "nomad_jobs/observability/inplace.nomad.hcl" 'job "inplace" { group "g" {} }'
write_job "nomad_jobs/bitcoin/replace.nomad.hcl" 'job "replace" {
  namespace = "bitcoin"
  group "g" {}
}'
RECONCILE_ROOT="$TMP/tree"
NOMAD_ADDR="http://127.0.0.1:9"
set +e
( main )
main_rc=$?
set -e
check "mixed plans exit 0" assert_eq "$main_rc" "0"
check "noop was planned" grep -q "job plan -no-color -namespace=default nomad_jobs/observability/noop.nomad.hcl" "$CALLS"
check "replace plan uses bitcoin namespace" grep -q "job plan -no-color -namespace=bitcoin nomad_jobs/bitcoin/replace.nomad.hcl" "$CALLS"
check "noop was not submitted" bash -c "! grep -q 'job run .*noop.nomad.hcl' '$CALLS'"
check "in-place submitted with check index" grep -q "job run -check-index 9 -namespace=default -no-color nomad_jobs/observability/inplace.nomad.hcl" "$CALLS"
check "create/destroy submitted with check index" grep -q "job run -check-index 11 -namespace=bitcoin -no-color nomad_jobs/bitcoin/replace.nomad.hcl" "$CALLS"
check "run did not pass detach" bash -c "! grep -q -- '-detach' '$CALLS'"

: >"$CALLS"
rm -rf "$TMP/tree/nomad_jobs"
write_job "nomad_jobs/plugins/a-planerr.nomad.hcl" 'job "planerr" { group "g" {} }'
write_job "nomad_jobs/plugins/z-inplace.nomad.hcl" 'job "inplace" { group "g" {} }'
set +e
( main )
main_rc=$?
set -e
check "plan error fails the run" assert_eq "$main_rc" "1"
check "later file still planned after plan error" grep -q "z-inplace.nomad.hcl" "$CALLS"
check "plan error was not submitted" bash -c "! grep -q 'job run .*planerr.nomad.hcl' '$CALLS'"

: >"$CALLS"
rm -rf "$TMP/tree/nomad_jobs"
write_job "nomad_jobs/plugins/a-downgrade.nomad.hcl" 'job "downgrade" { group "g" {} }'
write_job "nomad_jobs/plugins/z-okup.nomad.hcl" 'job "okup" { group "g" {} }'
LOG="$TMP/downgrade.log"
set +e
( main >"$LOG" 2>&1 )
main_rc=$?
set -e
check "downgrade refuses the run" assert_eq "$main_rc" "1"
check "downgrade plan was printed" grep -q 'MemoryMB: "4096" => "2048"' "$LOG"
check "downgrade job recorded as refused" grep -q "refused downgrade: nomad_jobs/plugins/a-downgrade.nomad.hcl" "$LOG"
check "downgrade plan secret redacted" assert_file_lacks "$LOG" "downgrade-secret"
check "downgrade was not submitted" bash -c "! grep -q 'job run .*downgrade.nomad.hcl' '$CALLS'"
check "non-downgrade still submitted after refusal" grep -q "job run -check-index 30 -namespace=default -no-color nomad_jobs/plugins/z-okup.nomad.hcl" "$CALLS"
check "downgrade run did not pass detach" bash -c "! grep -q -- '-detach' '$CALLS'"

: >"$CALLS"
rm -rf "$TMP/tree/nomad_jobs"
write_job "nomad_jobs/plugins/deployfail.nomad.hcl" 'job "deployfail" { group "g" {} }'
write_job "nomad_jobs/plugins/z-inplace.nomad.hcl" 'job "later" { group "g" {} }'
LOG="$TMP/deploy.log"
set +e
( main >"$LOG" 2>&1 )
main_rc=$?
set -e
check "deployment failure exits non-zero" assert_eq "$main_rc" "1"
check "later file not planned after deployment failure" bash -c "! grep -q 'job plan .*inplace.nomad.hcl' '$CALLS'"
check "alloc status requested" grep -q "alloc status -namespace=default -no-color abc12345" "$CALLS"
check "stdout logs requested" grep -q "alloc logs -namespace=default -no-color -n 100 abc12345 web" "$CALLS"
check "stderr logs requested" grep -q "alloc logs -namespace=default -no-color -stderr -n 100 abc12345 web" "$CALLS"
check "rpcauth redacted" assert_file_lacks "$LOG" "super-secret-value"
check "password redacted" assert_file_lacks "$LOG" "hunter2"
check "authkey redacted" assert_file_lacks "$LOG" "should-not-leak"
check "secret redacted" assert_file_lacks "$LOG" "secret=abcd"
check "stderr token redacted" assert_file_lacks "$LOG" "token=abcd"
check "redaction marker present" grep -q '\[redacted\]' "$LOG"
check "safe log line kept" grep -q "stdout line" "$LOG"

WF="$ROOT/.github/workflows/reconcile.yml"
check "workflow has no pull_request" bash -c "! grep -q pull_request '$WF'"
check "workflow is self-hosted" grep -q 'self-hosted, homelab' "$WF"
check "workflow does not cancel in progress" grep -q 'cancel-in-progress: false' "$WF"
check "workflow sets nomad addr" grep -q 'NOMAD_ADDR: http://192.168.68.65:4646' "$WF"
check "workflow comment tracks deployment" grep -q 'until the deployment succeeds' "$WF"

if grep -E -n 'ansible|midclt|nomad var get|node drain|job stop|job delete|reboot' "$ROOT/scripts/reconcile-nomad.sh" >/dev/null; then
  echo "FAIL script references a forbidden command" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok script has no forbidden commands"
  PASS=$((PASS + 1))
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
