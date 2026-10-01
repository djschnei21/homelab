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
    "node status")
      printf '%s\n' 'ID  DC  Name  Status' 'abc  homelab  pinode2  ready'
      return 0
      ;;
    "job inspect")
      printf '%s\n' 'bitcoin-stack/bitcoind image=bitcoin/bitcoin:31.1 cpu=1500 memory=4096'
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
check "tailscale directory default" assert_eq "$(namespace_for nomad_jobs/tailscale/tailscale-proxy.nomad.hcl)" "default"

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
assert_refuse() {
  local got="$1" needle="$2"
  [[ "$got" == "refuse "* && "$got" == *"$needle"* ]]
}

check "memory downgrade is refused" assert_refuse "$(plan_of 1 $'+/- MemoryMB: "4096" => "2048"\n\nJob Modify Index: 5')" 'MemoryMB: "4096" => "2048"'
check "cpu downgrade is refused" assert_refuse "$(plan_of 0 $'+/- CPU: "1500" => "500"\n\nJob Modify Index: 5')" 'CPU: "1500" => "500"'
check "memory max downgrade is refused" assert_refuse "$(plan_of 0 $'+/- MemoryMaxMB: "8192" => "4096"\n\nJob Modify Index: 5')" 'MemoryMaxMB: "8192" => "4096"'
check "memory upgrade still applies" assert_eq "$(plan_of 0 $'+/- MemoryMB: "2048" => "4096"\n\nJob Modify Index: 5')" "apply 5"
check "equal specs still apply" assert_eq "$(plan_of 0 $'+/- CPU: "1500" => "1500"\n+/- MemoryMB: "4096" => "4096"\n+/- image: "app:1.2.0" => "app:1.2.0"\n+/- Meta[version]: "1" => "2"\n\nJob Modify Index: 4')" "apply 4"
check "image downgrade is refused" assert_refuse "$(plan_of 1 $'+/- image: "bitcoin/bitcoin:31.1" => "bitcoin/bitcoin:30.2"\n\nJob Modify Index: 5')" 'image: "bitcoin/bitcoin:31.1" => "bitcoin/bitcoin:30.2"'
check "v-prefixed image downgrade is refused" assert_refuse "$(plan_of 0 $'+/- image: "getumbrel/electrs:v0.11.1" => "getumbrel/electrs:v0.10.10"\n\nJob Modify Index: 5')" 'getumbrel/electrs:v0.11.1'
check "shorter dotted downgrade is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:1.2.1" => "app:1.2"\n\nJob Modify Index: 5')" 'image: "app:1.2.1" => "app:1.2"'
check "numeric minor downgrade is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:1.10" => "app:1.9"\n\nJob Modify Index: 5')" 'image: "app:1.10" => "app:1.9"'
check "registry port tag downgrade is refused" assert_refuse "$(plan_of 0 $'+/- image: "localhost:5000/app:2.1" => "localhost:5000/app:1.0"\n\nJob Modify Index: 5')" 'localhost:5000/app:2.1'
check "image upgrade still applies" assert_eq "$(plan_of 0 $'+/- image: "ghcr.io/getalby/hub:v1.21.4" => "ghcr.io/getalby/hub:v1.24.0"\n\nJob Modify Index: 5')" "apply 5"
check "leading v equal to pin still applies" assert_eq "$(plan_of 0 $'+/- image: "app:v1.2.0" => "app:1.2.0"\n\nJob Modify Index: 5')" "apply 5"
check "suffix rollback is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:1.24.0-alpine" => "app:1.21.4-alpine"\n\nJob Modify Index: 5')" 'image: "app:1.24.0-alpine" => "app:1.21.4-alpine"'
check "suffix upgrade still applies" assert_eq "$(plan_of 0 $'+/- image: "app:1.21.4-alpine" => "app:1.24.0-alpine"\n\nJob Modify Index: 5')" "apply 5"
check "higher core may change suffix" assert_eq "$(plan_of 0 $'+/- image: "app:1.21.4-alpine" => "app:1.24.0-debian"\n\nJob Modify Index: 5')" "apply 5"
check "equal tag still applies" assert_eq "$(plan_of 0 $'+/- image: "app:1.24.0-alpine" => "app:1.24.0-alpine"\n\nJob Modify Index: 5')" "apply 5"
check "equal core suffix change is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:1.24.0-alpine3.20" => "app:1.24.0-alpine3.19"\n\nJob Modify Index: 5')" 'image: "app:1.24.0-alpine3.20" => "app:1.24.0-alpine3.19"'
check "equal core build metadata change is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:1.24.0+build.5" => "app:1.24.0+build.9"\n\nJob Modify Index: 5')" 'image: "app:1.24.0+build.5" => "app:1.24.0+build.9"'
check "latest to pin is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:latest" => "app:1.2.3"\n\nJob Modify Index: 5')" 'image: "app:latest" => "app:1.2.3"'
check "pin to latest is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:1.2.3" => "app:latest"\n\nJob Modify Index: 5')" 'image: "app:1.2.3" => "app:latest"'
check "unparseable tag change is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:stable" => "app:edge"\n\nJob Modify Index: 5')" 'image: "app:stable" => "app:edge"'
check "build metadata rollback is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:1.24.0+build.5" => "app:1.21.4+build.9"\n\nJob Modify Index: 5')" 'image: "app:1.24.0+build.5" => "app:1.21.4+build.9"'
check "image downgrade with memory upgrade is refused" assert_refuse "$(plan_of 0 $'+/- image: "app:2.0" => "app:1.0"\n+/- MemoryMB: "256" => "512"\n\nJob Modify Index: 5')" 'image: "app:2.0" => "app:1.0"'
check "annotated image upgrade still applies" assert_eq "$(plan_of 0 $'+/- image:           "bitcoin/bitcoin:30.2" => "bitcoin/bitcoin:31.1" (forces create/destroy update)\n\nJob Modify Index: 5')" "apply 5"

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
( GITHUB_ACTIONS=1 main >"$LOG" 2>&1 )
main_rc=$?
set -e
check "downgrade refuses the run" assert_eq "$main_rc" "1"
check "downgrade plan was printed" grep -q 'MemoryMB: "4096" => "2048"' "$LOG"
check "downgrade job recorded as refused" grep -q "refused downgrade: nomad_jobs/plugins/a-downgrade.nomad.hcl" "$LOG"
check "downgrade is a checks annotation" grep -q "::error::refused downgrade: nomad_jobs/plugins/a-downgrade.nomad.hcl" "$LOG"
check "downgrade plan secret redacted" assert_file_lacks "$LOG" "downgrade-secret"
check "downgrade was not submitted" bash -c "! grep -q 'job run .*downgrade.nomad.hcl' '$CALLS'"
check "non-downgrade still submitted after refusal" grep -q "job run -check-index 30 -namespace=default -no-color nomad_jobs/plugins/z-okup.nomad.hcl" "$CALLS"
check "downgrade run did not pass detach" bash -c "! grep -q -- '-detach' '$CALLS'"

: >"$CALLS"
rm -rf "$TMP/tree/nomad_jobs"
write_job "nomad_jobs/plugins/noop.nomad.hcl" 'job "noop" { group "g" {} }'
LOG="$TMP/status.log"
set +e
( RECONCILE_STATUS=1 GITHUB_ACTIONS=1 main >"$LOG" 2>&1 )
main_rc=$?
set -e
check "status probe exits 0" assert_eq "$main_rc" "0"
check "node status noticed" grep -q '::notice::node ' "$LOG"
check "registered task noticed" grep -q '::notice::registered bitcoin-stack/bitcoind image=bitcoin/bitcoin:31.1' "$LOG"

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
check "workflow shares the cluster lock" grep -q 'group: homelab-cluster' "$WF"
check "workflow records registered tasks" grep -q 'RECONCILE_STATUS: "1"' "$WF"

PATCH="$ROOT/.github/workflows/patch-infra.yml"
check "patch workflow has no pull_request" bash -c "! grep -q pull_request '$PATCH'"
check "patch workflow is self-hosted" grep -q 'self-hosted, homelab' "$PATCH"
check "patch workflow does not cancel in progress" grep -q 'cancel-in-progress: false' "$PATCH"
check "patch workflow shares the cluster lock" grep -q 'group: homelab-cluster' "$PATCH"
check "patch workflow can be dispatched" grep -q 'workflow_dispatch' "$PATCH"
check "patch workflow is scheduled" grep -q 'cron:' "$PATCH"
check "patch workflow runs the patch playbook" grep -q 'playbooks/patch_cluster.yml' "$PATCH"
check "patch ssh keeps host key checking" bash -c "! grep -q 'StrictHostKeyChecking=no' '$PATCH' && ! grep -q 'UserKnownHostsFile=/dev/null' '$PATCH' && ! grep -q 'ANSIBLE_HOST_KEY_CHECKING' '$PATCH'"
check "patch workflow passes the actions token" grep -q 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$PATCH"
check "patch playbook creates the result directory" grep -q 'state: directory' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "patch workflow does not run on push" bash -c "! grep -Eq '^[[:space:]]*push:' '$PATCH'"
check "patch workflow reports node status" grep -q 'nomad node status -no-color' "$PATCH"
check "patch workflow sets nomad addr" grep -q 'NOMAD_ADDR: http://192.168.68.65:4646' "$PATCH"
check "patch workflow fails if a node is not ready" grep -q 'a nomad node is not ready after patch' "$PATCH"
check "patch workflow publishes per-host results" grep -q 'homelab-patch-results' "$PATCH"
check "patch playbook records apt result" grep -q 'apt_changed=' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "patch workflow passes runner addresses" grep -q 'patch_runner_ips' "$PATCH"
check "patch playbook detects the runner by address" grep -q 'host_is_runner' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "patch playbook stops the roll when a client fails" grep -q 'any_errors_fatal: true' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "patch playbook undrains a failed client" grep -q 'drain disabled so the node can take work again' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "drain wait outlasts the deadline" awk '
  /Wait for drain to complete/ { waiting = 1 }
  waiting && /retries:/ { if (($2 + 0) < 120) exit 1; found = 1; waiting = 0 }
  END { exit !found }
' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "drain wait ignores LastDrain" bash -c "! grep -vE '^[[:space:]]*#' '$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml' | grep -q LastDrain"
check "client reboot waits for a slow card" grep -q 'reboot_timeout: 1200' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "client result failure does not stop the server" awk '
  /Record host patch result for the CI notice/ { n++ }
  n == 1 && /failed_when: false/ { found = 1 }
  n == 1 && /^- name: Patch Nomad Server/ { exit !found }
  END { exit !(n >= 1 && found) }
' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "patch result is recorded after the client is back" awk '
  /Record host patch result for the CI notice/ { if (!seen) exit 1; found = 1 }
  /Stop the roll after the client is eligible again/ { seen = 1 }
  END { exit !(seen && found) }
' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"

READY="$ROOT/.github/workflows/patch-ready.yml"
check "post-reboot check passes the actions token" grep -q 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$READY"
check "recheck attempt is not interpolated into the script" bash -c "! grep -q 'attempt=\"\${{ github.event.inputs.attempt' '$READY'"
check "patch workflow queues the post-reboot check" grep -q 'workflows/patch-ready.yml/dispatches' "$PATCH"
check "post-reboot check is not on push" bash -c "! grep -Eq '^[[:space:]]*push:' '$READY'"
check "post-reboot check is dispatched" grep -q 'workflow_dispatch:' "$READY"
check "post-reboot check stays on the homelab runner" bash -c "! grep -q 'ubuntu-latest' '$READY'"
check "post-reboot check requeues while reboot is scheduled" grep -q 'requeued Nomad recheck attempt' "$READY"
check "post-reboot check uses nomad addr" grep -q 'NOMAD_ADDR: http://192.168.68.65:4646' "$READY"
check "post-reboot check shares the cluster lock" grep -q 'group: homelab-cluster' "$READY"
check "post-reboot check waits for three clients" grep -q 'n >= 3' "$READY"
check "patch workflow requires three ready clients" grep -q 'n >= 3' "$PATCH"
check "patch workflow defers the runner reboot" grep -q 'patch_defer_runner_reboot=true' "$PATCH"
check "patch workflow reboots the runner after the readiness check" awk '
  /a nomad node is not ready after patch/ { failed = 1 }
  /workflows\/patch-ready.yml\/dispatches/ { if (!failed) exit 1; dispatched = 1 }
  /shutdown -r \+1/ { if (!dispatched) exit 1; found = 1 }
  END { exit !(failed && dispatched && found) }
' "$PATCH"
check "patch workflow bounds the nomad status call" grep -q 'timeout 15 nomad node status -no-color' "$PATCH"
check "post-reboot check bounds the nomad status call" grep -q 'timeout 15 nomad node status -no-color' "$READY"
check "manual runner reboot waits until nomad answers" awk '
  /Wait for Nomad server to be ready/ { waited = 1 }
  /shutdown -r \+2/ { if (!waited) exit 1; found = 1 }
  END { exit !(waited && found) }
' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "playbook can leave the runner reboot to CI" grep -q 'patch_defer_runner_reboot' "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"

# A workload identity reads only nomad/jobs/<job>, .../<group>, and
# .../<group>/<task> without a policy. A job or group path is shared with
# sibling tasks, so each template must read its own task path.
nomad_vars_use_task_paths() {
  awk '
    function quoted(s) { sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); return s }
    FNR == 1 { job = ""; group = ""; task = "" }
    /^[[:space:]]*job[[:space:]]+"/ { job = quoted($0) }
    /^[[:space:]]*group[[:space:]]+"/ { group = quoted($0); task = "" }
    /^[[:space:]]*task[[:space:]]+"/ { task = quoted($0) }
    {
      line = $0
      while (match(line, /nomadVar[[:space:]]+"[^"]*"/)) {
        path = quoted(substr(line, RSTART, RLENGTH))
        want = "nomad/jobs/" job "/" group "/" task
        if (path != want) { print FILENAME ": " path " is not " want > "/dev/stderr"; bad = 1 }
        n++
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { exit (bad || n == 0) }
  ' "$@"
}

mapfile -t JOB_FILES < <(find "$ROOT/nomad_jobs" -name '*.nomad.hcl' | sort)
check "every nomadVar reads its own task path" nomad_vars_use_task_paths "${JOB_FILES[@]}"
write_job "nomad_jobs/bitcoin/shared.nomad.hcl" 'job "shared" {
  group "g" {
    task "t" {
      template {
        data = <<EOT
{{ with nomadVar "nomad/jobs/shared/g/t" }}{{ end }}
{{ with nomadVar "nomad/jobs/shared" }}{{ end }}
EOT
      }
    }
  }
}'
rejects_shared_path() { ! nomad_vars_use_task_paths "$1" 2>/dev/null; }
check "a job-level nomadVar is rejected" rejects_shared_path "$TMP/tree/nomad_jobs/bitcoin/shared.nomad.hcl"

TS="$ROOT/nomad_jobs/tailscale/tailscale-proxy.nomad.hcl"
check "render task has an env workload identity" awk '
  /^[[:space:]]*task[[:space:]]+"/ { in_render = ($0 ~ /"render"/) }
  in_render && /^[[:space:]]*identity[[:space:]]*\{/ { in_id = 1 }
  in_id && /^[[:space:]]*env[[:space:]]*=[[:space:]]*true/ { found = 1 }
  in_id && /^[[:space:]]*\}/ { in_id = 0 }
  END { exit !found }
' "$TS"
check "render reads NOMAD_TOKEN" grep -q 'TOKEN = os.environ.get("NOMAD_TOKEN", "")' "$TS"
check "render sends the token on service lookups" grep -q 'headers={"X-Nomad-Token": TOKEN}' "$TS"

# The electrs-gw script as HCL hands it to the template engine. Template data
# gets one HCL pass, so $${ becomes ${ and nothing else changes.
electrs_gw_script() {
  awk '
    /^[[:space:]]*task[[:space:]]+"/ { in_gw = ($0 ~ /"electrs-gw"/) }
    in_gw && /<<EOF$/ { body = ""; in_data = 1; next }
    in_data && /^EOF$/ { in_data = 0; next }
    in_data { body = body $0 "\n"; next }
    in_gw && /destination[[:space:]]*=[[:space:]]*"local\/electrs-gw.sh"/ { printf "%s", body; found = 1; exit }
    END { exit !found }
  ' "$TS" | sed 's/\$\${/${/g'
}

electrs_target_for() {
  local env_file="$TMP/electrs.env" fn="$TMP/electrs_target.sh"
  printf '%s' "$1" >"$env_file"
  electrs_gw_script | awk '/^electrs_target\(\) \{/ { f = 1 } f { print } f && /^\}$/ { exit }' |
    sed "s#/alloc/electrs.env#${env_file}#" >"$fn"
  sh -c '. "$1" && electrs_target' sh "$fn"
}
electrs_rejects() { ! electrs_target_for "$1" >/dev/null 2>&1; }
check "electrs-gw serves the rendered upstream" \
  assert_eq "$(electrs_target_for $'ELECTRS_HOST=192.168.68.61\nELECTRS_PORT=50001\n')" "tcp://192.168.68.61:50001"
check "electrs-gw rejects a host with shell syntax" electrs_rejects $'ELECTRS_HOST=$(id)\nELECTRS_PORT=50001\n'

electrs_gw_key_from_file() {
  local script
  script="$(electrs_gw_script)"
  [[ "$script" == *'--auth-key="file:$NOMAD_SECRETS_DIR/ts_authkey"'* && "$script" != *TS_AUTHKEY* ]] || return 1
  awk '
    /^[[:space:]]*task[[:space:]]+"/ { in_gw = ($0 ~ /"electrs-gw"/) }
    in_gw && /^[[:space:]]*destination[[:space:]]*=/ && index($0, "\"${NOMAD_SECRETS_DIR}/ts_authkey\"") { found = 1 }
    in_gw && /^[[:space:]]*env[[:space:]]*=[[:space:]]*true/ { bad = 1 }
    END { exit (bad || !found) }
  ' "$TS"
}
check "electrs-gw reads its auth key from a secrets file" electrs_gw_key_from_file

warm_proxy_matches() {
  local render_port gw_port
  render_port="$(sed -n 's/^WARM_PROXY = ("127.0.0.1", \([0-9]*\))$/\1/p' "$TS")"
  gw_port="$(sed -n 's/.*--outbound-http-proxy-listen=127.0.0.1:\([0-9]*\).*/\1/p' "$TS")"
  [[ -n "$render_port" && "$render_port" == "$gw_port" ]]
}
check "render warms through electrs-gw's proxy port" warm_proxy_matches

WARM_DIR="$TMP/warm"
mkdir -p "$WARM_DIR"
awk '
  /^[[:space:]]*task[[:space:]]+"/ { in_render = ($0 ~ /"render"/) }
  in_render && /<<EOF$/ { in_data = 1; next }
  in_data && /^EOF$/ { exit }
  in_data { print }
' "$TS" | sed 's/\$\${/${/g' >"$WARM_DIR/render.py"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj /CN=warm-test -addext 'subjectAltName=DNS:*.example.ts.net' \
  -keyout "$WARM_DIR/key.pem" -out "$WARM_DIR/cert.pem" >/dev/null 2>&1

# Runs render.py's warm-up against a local CONNECT proxy and TLS server. "up"
# trusts the server cert, "untrusted" does not, and "down" has no proxy.
warm_case() {
  TS_TAILNET=example.ts.net timeout 30 python3 - "$WARM_DIR" "$1" <<'PY'
import importlib.util, os, socket, ssl, sys, threading

d, mode = sys.argv[1], sys.argv[2]
if mode != "untrusted":
    os.environ["SSL_CERT_FILE"] = f"{d}/cert.pem"
spec = importlib.util.spec_from_file_location("render", f"{d}/render.py")
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
seen = []

def listener():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen()
    return s

tls = listener()
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
sctx.load_cert_chain(f"{d}/cert.pem", f"{d}/key.pem")
sctx.sni_callback = lambda sock, name, ctx: seen.append(f"sni {name}")

def serve_tls():
    while True:
        c, _ = tls.accept()
        try:
            sctx.wrap_socket(c, server_side=True).close()
        except OSError:
            c.close()

def pipe(a, b):
    try:
        while data := a.recv(65536):
            b.sendall(data)
        b.shutdown(socket.SHUT_WR)
    except OSError:
        pass

proxy = listener()

def serve_proxy():
    while True:
        c, _ = proxy.accept()
        buf = b""
        while b"\r\n\r\n" not in buf and (chunk := c.recv(4096)):
            buf += chunk
        seen.append(buf.split(b"\r\n", 1)[0].decode())
        u = socket.create_connection(tls.getsockname())
        c.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
        threading.Thread(target=pipe, args=(c, u), daemon=True).start()
        threading.Thread(target=pipe, args=(u, c), daemon=True).start()

threading.Thread(target=serve_tls, daemon=True).start()
threading.Thread(target=serve_proxy, daemon=True).start()
closed = listener()
r.WARM_PROXY = closed.getsockname() if mode == "down" else proxy.getsockname()
closed.close()
r.WARM_RETRY = 0.05
r.WARM_SECONDS = 5 if mode == "up" else 1
r.svc = lambda name, ns="default": ("10.0.0.1", 8080)
caddy, _ = r.render()
for t in r.start_warm(caddy):
    t.join(15)
    if t.is_alive():
        print("warm thread still running")
for line in sorted(seen):
    print(line)
PY
}

warm_up_ok() {
  local out site
  out="$(warm_case up)"
  for site in alby grafana mempool prometheus; do
    if ! grep -qx "warmed ${site}" <<<"$out" ||
      ! grep -qx "CONNECT ${site}.example.ts.net:443 HTTP/1.1" <<<"$out" ||
      ! grep -qx "sni ${site}.example.ts.net" <<<"$out"; then
      printf '%s\n' "$out" >&2
      return 1
    fi
  done
}
warm_gives_up() {
  local out
  out="$(warm_case "$1")"
  if [[ "$(grep -c '^warm failed ' <<<"$out")" != 4 ]] || grep -q -e '^warmed ' -e 'still running' <<<"$out"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
}
check "render warms every site through the proxy" warm_up_ok
check "render warm-up rejects an untrusted cert" warm_gives_up untrusted
check "render warm-up gives up when the proxy is down" warm_gives_up down

# Body of a workflow step's `run: |` block, dedented.
workflow_step_script() {
  awk -v step="$2" '
    $0 ~ "- name: " step "$" { found = 1; next }
    found && !inrun && /^[[:space:]]*run: \|/ { match($0, /^[[:space:]]*/); base = RLENGTH; inrun = 1; next }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= base) exit
      print substr($0, base + 3)
    }
  ' "$1"
}

# Runs a workflow's token step against a fake HOME. Prints the exit code, what
# it wrote to GITHUB_ENV, and every output line that carries the token.
FAKE_TOKEN="00000000-0000-4000-8000-000000000000"
token_step_case() {
  local wf="$1" file="$2" content="$3" home rc
  home="$(mktemp -d)"
  : >"$home/github_env"
  if [[ -n "$file" ]]; then
    mkdir -p "$home/.nomad"
    printf '%s' "$content" >"$home/.nomad/$file"
  fi
  set +e
  HOME="$home" GITHUB_ENV="$home/github_env" \
    bash -c "$(workflow_step_script "$wf" 'Load Nomad token')" >"$home/out" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc"
  cat "$home/github_env"
  grep -F -- "$FAKE_TOKEN" "$home/out" || true
  rm -rf "$home"
}

for spec in reconcile.yml:reconcile.token:patch.token \
  patch-infra.yml:patch.token:reconcile.token \
  patch-ready.yml:patch.token:reconcile.token; do
  IFS=: read -r wf_name own_file other_file <<<"$spec"
  wf_path="$ROOT/.github/workflows/$wf_name"
  check "${wf_name} has a token step" test -n "$(workflow_step_script "$wf_path" 'Load Nomad token')"
  check "${wf_name} runs without a token file" \
    assert_eq "$(token_step_case "$wf_path" "" "")" "0"
  check "${wf_name} ignores the other workflow's token file" \
    assert_eq "$(token_step_case "$wf_path" "$other_file" "$FAKE_TOKEN")" "0"
  check "${wf_name} masks and exports its own token" \
    assert_eq "$(token_step_case "$wf_path" "$own_file" "$FAKE_TOKEN"$'\n')" \
    "0"$'\n'"NOMAD_TOKEN=${FAKE_TOKEN}"$'\n'"::add-mask::${FAKE_TOKEN}"
  check "${wf_name} rejects a malformed token file" \
    assert_eq "$(token_step_case "$wf_path" "$own_file" $'not-a-token\nBASH_ENV=/tmp/x')" "1"
done

step_precedes() {
  awk -v first="- name: $2" -v second="- name: $3" '
    index($0, first) { seen = 1 }
    index($0, second) { exit !seen }
  ' "$1"
}
check "reconcile loads the token before nomad runs" step_precedes "$WF" "Load Nomad token" "Reconcile Nomad jobs"
check "patch loads the token before the playbook" step_precedes "$PATCH" "Load Nomad token" "Patch Nomad hosts"
check "post-reboot check loads the token before nomad runs" step_precedes "$READY" "Load Nomad token" "Confirm Nomad nodes are ready"

TOKEN_ENV_LINE="NOMAD_TOKEN: \"{{ lookup('ansible.builtin.env', 'NOMAD_TOKEN') }}\""
every_play_passes_token() {
  local plays passed
  plays="$(grep -c '^  hosts:' "$1")"
  passed="$(grep -cF -- "$TOKEN_ENV_LINE" "$1")"
  [[ "$plays" -gt 0 && "$plays" == "$passed" ]]
}
check "patch playbook passes NOMAD_TOKEN to every play" every_play_passes_token "$ROOT/bootstrap/nomad/playbooks/patch_cluster.yml"
check "migration playbook passes NOMAD_TOKEN to every play" every_play_passes_token "$ROOT/bootstrap/nomad/playbooks/migrate_pinode2_to_pinode1.yml"

acl_block_enabled() {
  awk '
    /^acl[[:space:]]*\{/ { in_acl = 1; next }
    in_acl && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true/ { found = 1 }
    in_acl && /^\}/ { in_acl = 0 }
    END { exit !found }
  ' "$1"
}
check "server config enables ACLs" acl_block_enabled "$ROOT/bootstrap/nomad/roles/nomad_server/templates/server.hcl.j2"
check "client config enables ACLs" acl_block_enabled "$ROOT/bootstrap/nomad/roles/nomad_client/templates/client.hcl.j2"
check "client introduction is left at its default" bash -c "! grep -rq client_introduction '$ROOT/bootstrap/nomad/roles'"

POL="$ROOT/nomad_acl/policies"
policies_lack() { ! grep -hv '^[[:space:]]*#' "$POL"/*.hcl | grep -Eq "$1"; }
check "no anonymous policy" test ! -e "$POL/anonymous.hcl"
check "policies grant no variable access" policies_lack 'variables'
check "policies grant no broad job rights" policies_lack 'submit-job|alloc-exec|alloc-lifecycle|read-fs|csi-write-volume|management'
check "only ci-patch has a write policy" \
  assert_eq "$(grep -lE '^[[:space:]]*policy[[:space:]]*=[[:space:]]*"write"' "$POL"/*.hcl)" "$POL/ci-patch.hcl"
check "ci-patch writes only nodes" \
  assert_eq "$(grep -B1 -E '^[[:space:]]*policy[[:space:]]*=[[:space:]]*"write"' "$POL/ci-patch.hcl")" $'node {\n  policy = "write"'

if grep -E -n 'ansible|midclt|nomad var get|node drain|job stop|job delete|reboot|namespace apply|volume register|nomad acl' "$ROOT/scripts/reconcile-nomad.sh" >/dev/null; then
  echo "FAIL script references a forbidden command" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok script has no forbidden commands"
  PASS=$((PASS + 1))
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
