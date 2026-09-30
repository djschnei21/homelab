#!/usr/bin/env bash
# Reconcile nomad_jobs/*.nomad.hcl with the cluster.
#
# Nomad 2.0 `job plan` exit codes (command reference):
#   0   no allocations created or destroyed (a diff may still exist)
#   1   allocations created or destroyed — changes, not a script failure
#   255 error determining plan results
# Exit 0 with an empty diff is a pass. A diff that lowers memory, CPU, or a
# comparable image version is a downgrade and is not submitted. Any other real
# diff is submitted with `nomad job run -check-index` and no -detach, so Nomad
# tracks the deployment. Refused downgrades still fail the run after every
# other job is handled.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${RECONCILE_ROOT:-}" ]]; then
  ROOT="$RECONCILE_ROOT"
fi

# Whole line, not a substring: plan diffs and task logs can carry rpc auth.
redact() {
  local line lower
  while IFS= read -r line || [[ -n "$line" ]]; do
    lower="${line,,}"
    if [[ "$lower" == *rpcauth* || "$lower" == *password* || "$lower" == *token* || "$lower" == *secret* || "$lower" == *authkey* ]]; then
      printf '%s\n' '[redacted]'
    else
      printf '%s\n' "$line"
    fi
  done
}

# Directory default, then a job-level namespace attribute if the file sets one.
namespace_for() {
  local file="$1" dir_ns="" file_ns=""
  case "$file" in
    nomad_jobs/bitcoin/*) dir_ns="bitcoin" ;;
    nomad_jobs/observability/* | nomad_jobs/plugins/*) dir_ns="default" ;;
    *)
      echo "no namespace mapping for ${file}" >&2
      return 1
      ;;
  esac

  file_ns="$(
    awk '
      function strip(s) {
        sub(/[[:space:]]+#.*$/, "", s)
        sub(/[[:space:]]+\/\/.*$/, "", s)
        return s
      }
      /^[[:space:]]*(#|\/\/)/ { next }
      {
        line = strip($0)
        if (line ~ /^[[:space:]]*group[[:space:]]+"/) {
          exit
        }
        if (match(line, /^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"[^"]+"/)) {
          value = line
          sub(/^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"/, "", value)
          sub(/".*$/, "", value)
          print value
          exit
        }
      }
    ' "$file"
  )"

  if [[ -n "$file_ns" ]]; then
    printf '%s\n' "$file_ns"
  else
    printf '%s\n' "$dir_ns"
  fi
}

job_name_from_file() {
  local file="$1" name
  name="$(sed -n 's/^job[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
  if [[ -z "$name" ]]; then
    echo "no job name in ${file}" >&2
    return 1
  fi
  printf '%s\n' "$name"
}

# Tag after the last slash. A colon earlier in the reference is a registry port.
image_tag() {
  local ref="$1" name
  ref="${ref%%@*}"
  name="${ref##*/}"
  if [[ "$name" == *:* ]]; then
    printf '%s\n' "${name##*:}"
  fi
}

# 0 when left is a higher dotted version than right. `latest` and any tag that
# is not a dotted number (after one leading v) are not comparable.
version_is_higher() {
  local left="$1" right="$2"
  if [[ -z "$left" || -z "$right" || "$left" == "latest" || "$right" == "latest" ]]; then
    return 1
  fi
  left="${left#v}"
  right="${right#v}"
  if [[ ! "$left" =~ ^[0-9]+(\.[0-9]+)*$ || ! "$right" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    return 1
  fi

  local IFS=.
  local -a left_parts=() right_parts=()
  read -r -a left_parts <<< "$left"
  read -r -a right_parts <<< "$right"

  local i count left_n right_n
  count=${#left_parts[@]}
  if (( ${#right_parts[@]} > count )); then
    count=${#right_parts[@]}
  fi
  for ((i = 0; i < count; i++)); do
    left_n="${left_parts[$i]:-0}"
    right_n="${right_parts[$i]:-0}"
    if (( 10#$left_n > 10#$right_n )); then
      return 0
    fi
    if (( 10#$left_n < 10#$right_n )); then
      return 1
    fi
  done
  return 1
}

resource_line_is_downgrade() {
  local line="$1" old new
  if [[ "$line" =~ (^|[[:space:]])(CPU|MemoryMB|MemoryMaxMB)[[:space:]]*:[[:space:]]*\"([0-9]+)\"[[:space:]]*=\>[[:space:]]*\"([0-9]+)\" ]]; then
    old="${BASH_REMATCH[3]}"
    new="${BASH_REMATCH[4]}"
    if (( 10#$new < 10#$old )); then
      return 0
    fi
  fi
  return 1
}

image_line_is_downgrade() {
  local line="$1" old_ref new_ref
  if [[ "$line" =~ (^|[[:space:]])image[[:space:]]*:[[:space:]]*\"([^\"]+)\"[[:space:]]*=\>[[:space:]]*\"([^\"]+)\" ]]; then
    old_ref="${BASH_REMATCH[2]}"
    new_ref="${BASH_REMATCH[3]}"
    if version_is_higher "$(image_tag "$old_ref")" "$(image_tag "$new_ref")"; then
      return 0
    fi
  fi
  return 1
}

plan_is_downgrade() {
  local plan_file="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if resource_line_is_downgrade "$line" || image_line_is_downgrade "$line"; then
      return 0
    fi
  done <"$plan_file"
  return 1
}

# Prints one of: noop | apply <index> | refuse | error <reason>
plan_decision() {
  local rc="$1" plan_file="$2" index="" has_diff=0
  local indexes=()

  if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    printf 'error plan-exit-%s\n' "$rc"
    return 0
  fi

  mapfile -t indexes < <(grep -E '^Job Modify Index: [0-9]+$' "$plan_file" | awk '{print $4}' || true)
  if [[ "${#indexes[@]}" -eq 1 ]]; then
    index="${indexes[0]}"
  elif [[ "${#indexes[@]}" -gt 1 ]]; then
    printf 'error ambiguous-check-index\n'
    return 0
  fi

  if grep -Eq '^[[:space:]]*(\+/-|\+|-)[[:space:]]' <(
    awk 'BEGIN { keep = 1 } /^Scheduler dry-run:/ { keep = 0 } keep { print }' "$plan_file"
  ); then
    has_diff=1
  fi

  # Exit 1 is the documented "allocations created or destroyed" result.
  if [[ "$rc" -eq 1 ]]; then
    has_diff=1
  fi

  if [[ "$has_diff" -eq 0 ]]; then
    printf 'noop\n'
    return 0
  fi

  # A downgrade is refused: the cluster must not move backward even when main says so.
  if plan_is_downgrade "$plan_file"; then
    printf 'refuse\n'
    return 0
  fi

  if [[ -z "$index" ]]; then
    printf 'error missing-check-index\n'
    return 0
  fi

  printf 'apply %s\n' "$index"
}

print_failure_diagnostics() {
  local ns="$1" job="$2" status_file allocs_file alloc task
  status_file="$(mktemp)"
  allocs_file="$(mktemp)"

  echo "--- job status ${job} (namespace ${ns}) ---"
  set +e
  nomad job status -namespace="$ns" -no-color "$job" >"$status_file" 2>&1
  set -e
  redact <"$status_file"

  awk '
    /^Allocations$/ { in_alloc = 1; next }
    in_alloc && /^$/ { exit }
    in_alloc && /^[0-9a-f]{8}/ { print $1 }
  ' "$status_file" >"$allocs_file.all"
  head -n 8 "$allocs_file.all" >"$allocs_file"
  rm -f "$allocs_file.all"

  if [[ ! -s "$allocs_file" ]]; then
    echo "no allocation ids in job status"
  fi

  while IFS= read -r alloc; do
    [[ -z "$alloc" ]] && continue
    local alloc_status
    alloc_status="$(mktemp)"
    echo "--- alloc status ${alloc} ---"
    set +e
    nomad alloc status -namespace="$ns" -no-color "$alloc" >"$alloc_status" 2>&1
    set -e
    redact <"$alloc_status"

    local tasks=()
    mapfile -t tasks < <(sed -n 's/^Task "\([^"]*\)" is .*/\1/p' "$alloc_status" || true)
    if [[ "${#tasks[@]}" -eq 0 ]]; then
      echo "no task names in alloc status ${alloc}; skipping logs"
      rm -f "$alloc_status"
      continue
    fi

    for task in "${tasks[@]}"; do
      echo "--- alloc logs ${alloc} task ${task} (stdout, last 100 lines) ---"
      set +e
      nomad alloc logs -namespace="$ns" -no-color -n 100 "$alloc" "$task" 2>&1 | redact
      echo "--- alloc logs ${alloc} task ${task} (stderr, last 100 lines) ---"
      nomad alloc logs -namespace="$ns" -no-color -stderr -n 100 "$alloc" "$task" 2>&1 | redact
      set -e
    done
    rm -f "$alloc_status"
  done <"$allocs_file"

  rm -f "$status_file" "$allocs_file"
}

# Returns 0 on success, 1 on plan error, 10 on deployment failure.
reconcile_one() {
  local file="$1" ns plan_file plan_rc decision index run_rc
  echo "==> ${file}"

  if ! ns="$(namespace_for "$file")"; then
    return 1
  fi
  echo "namespace ${ns}"

  plan_file="$(mktemp)"
  set +e
  nomad job plan -no-color -namespace="$ns" "$file" >"$plan_file" 2>&1
  plan_rc=$?
  set -e

  echo "plan exit ${plan_rc}"
  redact <"$plan_file"

  decision="$(plan_decision "$plan_rc" "$plan_file")"
  rm -f "$plan_file"

  case "$decision" in
    noop)
      echo "no diff"
      return 0
      ;;
    apply\ *)
      index="${decision#apply }"
      ;;
    refuse)
      echo "refused downgrade: ${file}"
      return 1
      ;;
    error\ *)
      echo "plan error: ${decision#error }" >&2
      return 1
      ;;
    *)
      echo "unparsed plan decision: ${decision}" >&2
      return 1
      ;;
  esac

  echo "submitting ${file} -check-index ${index}"
  set +e
  set +o pipefail
  nomad job run -check-index "$index" -namespace="$ns" -no-color "$file" 2>&1 | redact
  run_rc="${PIPESTATUS[0]}"
  set -o pipefail
  set -e

  if [[ "$run_rc" -ne 0 ]]; then
    echo "deployment failed: ${file} (nomad job run exit ${run_rc})" >&2
    local job
    if job="$(job_name_from_file "$file")"; then
      print_failure_diagnostics "$ns" "$job" || true
    fi
    return 10
  fi

  echo "deployment succeeded: ${file}"
  return 0
}

main() {
  local file failed=0 rc root="$ROOT"
  if [[ -n "${RECONCILE_ROOT:-}" ]]; then
    root="$RECONCILE_ROOT"
  fi
  cd "$root"

  if [[ -z "${NOMAD_ADDR:-}" ]]; then
    echo "NOMAD_ADDR is not set" >&2
    exit 1
  fi

  local files=()
  mapfile -t files < <(find nomad_jobs -type f -name '*.nomad.hcl' | sort)
  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "no job files under nomad_jobs/" >&2
    exit 1
  fi

  for file in "${files[@]}"; do
    # reconcile_one toggles set -e internally; an OR list keeps a non-zero
    # return from aborting the loop before the status is recorded.
    rc=0
    reconcile_one "$file" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      continue
    fi
    if [[ "$rc" -eq 10 ]]; then
      exit 1
    fi
    failed=1
  done

  exit "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
