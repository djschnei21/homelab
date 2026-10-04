#!/usr/bin/env bash
# Reconcile nomad_jobs/*.nomad.hcl with the cluster.
#
# Nomad 2.0 `job plan` exit codes (command reference):
#   0   no allocations created or destroyed (a diff may still exist)
#   1   allocations created or destroyed — changes, not a script failure
#   255 error determining plan results
# Exit 0 with an empty diff is a pass. A diff that lowers MemoryMB, MemoryMaxMB,
# or CPU is not submitted unless that job's decrease is declared. Removing
# memory_max (MemoryMaxMB N => 0) is a decrease; adding it (0 => N) is not. An
# image change is not submitted when the numeric core decreases, when an equal
# core changes suffix or build metadata, or when the tags differ and the new
# tag is not a higher version (`latest`, or any tag that does not parse).
# Identical tags, and a lone leading v on an otherwise identical tag, are not
# downgrades. A higher core may change suffix. A declaration never lets a
# refused image change through. Any other real diff is submitted with
# `nomad job run -check-index` and no -detach, so Nomad tracks the deployment.
# Refused jobs still fail the run after every other job is handled.
#
# A decrease is declared per job name on its own line of a commit message:
#
#   Allow-Resource-Decrease: <job>[, <job>...]
#
# A push run reads every commit in RECONCILE_BEFORE..RECONCILE_AFTER. Put the
# line in a commit on the PR branch, not in the PR body. A squash commit's body
# is the branch's commit messages, and merge or rebase keeps the commits. A
# manual run takes the same job list in RECONCILE_ALLOW_DECREASE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${RECONCILE_ROOT:-}" ]]; then
  ROOT="$RECONCILE_ROOT"
fi

# Checks annotations are readable here; the Actions log blob host is not.
# Keep the message on one line so the workflow command survives the log pipe.
ci_error() {
  local msg="$1" escaped
  msg="${msg:0:400}"
  printf '%s\n' "$msg" >&2
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$msg" >>"${GITHUB_STEP_SUMMARY}"
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    escaped="${msg//%/%25}"
    escaped="${escaped//$'\n'/%0A}"
    printf '::error::%s\n' "$escaped"
  fi
}

gh_notice() {
  local msg="$1" escaped
  msg="${msg:0:400}"
  printf '%s\n' "$msg"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$msg" >>"${GITHUB_STEP_SUMMARY}"
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    escaped="${msg//%/%25}"
    printf '::notice::%s\n' "$escaped"
  fi
}

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
    nomad_jobs/observability/* | nomad_jobs/plugins/* | nomad_jobs/tailscale/*) dir_ns="default" ;;
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

# Dotted numeric core, or empty when the tag is not a version. One leading v
# is optional and is not part of the core.
version_core() {
  local tag="$1"
  if [[ "$tag" == v* ]]; then
    tag="${tag#v}"
  fi
  if [[ "$tag" =~ ^([0-9]+(\.[0-9]+)*)([-+].+)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# Suffix or build metadata, including the leading - or +. Empty when the tag
# has none. Group 2 is the last dotted component, so the metadata is group 3.
version_suffix() {
  local tag="$1"
  if [[ "$tag" == v* ]]; then
    tag="${tag#v}"
  fi
  if [[ "$tag" =~ ^([0-9]+(\.[0-9]+)*)([-+].+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[3]}"
  fi
}

# 0 when left's numeric core is strictly higher than right's.
numeric_core_is_higher() {
  local left="$1" right="$2"
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

# MemoryMaxMB 0 means no memory_max, so the hard limit falls back to MemoryMB.
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

# Identical tags are not a change. A higher numeric core is an upgrade even
# when the suffix changes. An equal core is refused when suffix or build
# metadata differs. The same remaining tag with one leading v is not a
# downgrade. latest, or any tag that does not parse, is refused when the
# strings differ.
image_line_is_downgrade() {
  local line="$1" old_ref new_ref old_tag new_tag old_core new_core
  local old_bare new_bare old_suffix new_suffix
  if [[ "$line" =~ (^|[[:space:]])image[[:space:]]*:[[:space:]]*\"([^\"]+)\"[[:space:]]*=\>[[:space:]]*\"([^\"]+)\" ]]; then
    old_ref="${BASH_REMATCH[2]}"
    new_ref="${BASH_REMATCH[3]}"
    old_tag="$(image_tag "$old_ref")"
    new_tag="$(image_tag "$new_ref")"
    if [[ "$old_tag" == "$new_tag" ]]; then
      return 1
    fi
    old_core="$(version_core "$old_tag")"
    new_core="$(version_core "$new_tag")"
    if [[ -n "$old_core" && -n "$new_core" ]]; then
      if numeric_core_is_higher "$new_core" "$old_core"; then
        return 1
      fi
      if numeric_core_is_higher "$old_core" "$new_core"; then
        return 0
      fi
      old_bare="${old_tag#v}"
      new_bare="${new_tag#v}"
      if [[ "$old_bare" == "$new_bare" ]]; then
        return 1
      fi
      old_suffix="$(version_suffix "$old_tag")"
      new_suffix="$(version_suffix "$new_tag")"
      if [[ "$old_suffix" != "$new_suffix" ]]; then
        return 0
      fi
      # 1.2 and 1.2.0 share a numeric core and have no suffix.
      return 1
    fi
    return 0
  fi
  return 1
}

plan_image_downgrade() {
  local plan_file="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if image_line_is_downgrade "$line"; then
      printf '%s\n' "${line#"${line%%[![:space:]]*}"}"
      return 0
    fi
  done <"$plan_file"
  return 1
}

plan_resource_decreases() {
  local plan_file="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if resource_line_is_downgrade "$line"; then
      printf '%s\n' "${line#"${line%%[![:space:]]*}"}"
    fi
  done <"$plan_file"
}

DECREASE_JOBS=()

# The key is case-insensitive, as in a git trailer, but the line can sit
# anywhere in the message: a squash commit lists each branch commit's body
# under its subject.
decrease_trailer_values() {
  local line key
  while IFS= read -r line || [[ -n "$line" ]]; do
    key="${line%%:*}"
    if [[ "$line" == *:* && "${key,,}" == allow-resource-decrease ]]; then
      printf '%s\n' "${line#*:}"
    fi
  done
}

# Nomad job IDs hold no spaces, so commas and whitespace both separate names.
add_decrease_jobs() {
  local name
  local -a names=()
  IFS=$', \t\r' read -r -a names <<<"$1"
  for name in "${names[@]}"; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      DECREASE_JOBS+=("$name")
    else
      gh_notice "ignored Allow-Resource-Decrease entry: ${name}"
    fi
  done
}

# A range that cannot be read declares nothing, so decreases stay refused.
# The notice is the only record a run leaves of what it read: the Actions log
# is not readable from outside the LAN.
load_decrease_declarations() {
  local before="${RECONCILE_BEFORE:-}" after="${RECONCILE_AFTER:-}" messages value source=""
  local sha='^[0-9a-f]{40}([0-9a-f]{24})?$'
  DECREASE_JOBS=()
  if [[ -n "$before" || -n "$after" ]]; then
    if [[ "$before" =~ $sha && "$after" =~ $sha && ! "$before" =~ ^0+$ ]] &&
      messages="$(git log --format=%B "${before}..${after}" 2>/dev/null)"; then
      while IFS= read -r value; do
        add_decrease_jobs "$value"
      done < <(decrease_trailer_values <<<"$messages")
      source="commits ${before:0:12}..${after:0:12}"
    else
      gh_notice "cannot read commits ${before:0:12}..${after:0:12}; no resource decrease declared by commit"
    fi
  fi
  if [[ -n "${RECONCILE_ALLOW_DECREASE:-}" ]]; then
    add_decrease_jobs "$RECONCILE_ALLOW_DECREASE"
    source="${source:+${source} and }dispatch input"
  fi
  gh_notice "resource decrease declared for: ${DECREASE_JOBS[*]:-none}${source:+ (from ${source})}"
}

decrease_declared() {
  local name
  for name in "${DECREASE_JOBS[@]}"; do
    if [[ "$name" == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# Prints one of: noop | apply <index> | refuse <line> | error <reason>
# A third argument of 1 lets MemoryMB, MemoryMaxMB, and CPU decrease.
plan_decision() {
  local rc="$1" plan_file="$2" allow_decrease="${3:-0}" index="" has_diff=0
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

  # Refused when main would move an image backward, or when an image change
  # cannot be proved equal or higher, whatever is declared. Memory and CPU
  # may move backward only when declared.
  local reason=""
  if reason="$(plan_image_downgrade "$plan_file")"; then
    printf 'refuse %s\n' "$reason"
    return 0
  fi
  reason="$(plan_resource_decreases "$plan_file")"
  if [[ -n "$reason" && "$allow_decrease" != 1 ]]; then
    printf 'refuse %s\n' "${reason%%$'\n'*}"
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
  local file="$1" ns plan_file plan_rc decision index run_rc plan_err=""
  local job="" allow_decrease=0 decreases="" line
  echo "==> ${file}"

  if ! ns="$(namespace_for "$file")"; then
    ci_error "no namespace for ${file}"
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

  plan_err="$(grep -m1 -E 'Error|error|failed' "$plan_file" || true)"
  if job="$(job_name_from_file "$file")" && decrease_declared "$job"; then
    allow_decrease=1
  fi
  decision="$(plan_decision "$plan_rc" "$plan_file" "$allow_decrease")"
  if [[ "$allow_decrease" -eq 1 && "$decision" == apply\ * ]]; then
    decreases="$(plan_resource_decreases "$plan_file")"
  fi
  rm -f "$plan_file"

  case "$decision" in
    noop)
      echo "no diff"
      return 0
      ;;
    apply\ *)
      index="${decision#apply }"
      ;;
    refuse*)
      line="${decision#refuse }"
      if resource_line_is_downgrade "$line"; then
        line="${line}; declare it with Allow-Resource-Decrease: ${job:-<job>}"
      fi
      echo "refused downgrade: ${file}: ${line}"
      ci_error "refused downgrade: ${file}: ${line}"
      return 1
      ;;
    error\ *)
      ci_error "plan error: ${file}: ${decision#error } ${plan_err}"
      return 1
      ;;
    *)
      ci_error "unparsed plan decision: ${file}: ${decision}"
      return 1
      ;;
  esac

  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      gh_notice "allowed resource decrease for job ${job} (${file}): ${line}"
    fi
  done <<<"$decreases"

  echo "submitting ${file} -check-index ${index}"
  local run_out
  run_out="$(mktemp)"
  set +e
  set +o pipefail
  nomad job run -check-index "$index" -namespace="$ns" -no-color "$file" 2>&1 | redact | tee "$run_out"
  run_rc="${PIPESTATUS[0]}"
  set -o pipefail
  set -e

  if [[ "$run_rc" -ne 0 ]]; then
    ci_error "deployment failed: ${file} (nomad job run exit ${run_rc}) $(tail -n 1 "$run_out")"
    rm -f "$run_out"
    if [[ -n "$job" ]]; then
      print_failure_diagnostics "$ns" "$job" || true
    fi
    return 10
  fi

  rm -f "$run_out"
  echo "deployment succeeded: ${file}"
  return 0
}

# Registered tasks are emitted as checks notices. Actions log blobs are not
# readable from outside the LAN, and the next reconcile has to show what the
# cluster is actually running.
note_cluster_status() {
  local file ns name out rc line
  out="$(mktemp)"
  set +e
  nomad node status -no-color >"$out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    ci_error "nomad node status failed: $(head -n 1 "$out")"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      gh_notice "node ${line}"
    done <"$out"
  fi
  rm -f "$out"

  for file in "$@"; do
    if ! ns="$(namespace_for "$file")"; then
      continue
    fi
    if ! name="$(job_name_from_file "$file")"; then
      continue
    fi
    out="$(mktemp)"
    set +e
    nomad job inspect -namespace="$ns" -t '{{range .TaskGroups}}{{range .Tasks}}{{$.ID}}/{{.Name}} image={{index .Config "image"}} cpu={{if .Resources}}{{.Resources.CPU}}{{end}} memory={{if .Resources}}{{.Resources.MemoryMB}}{{end}}{{println}}{{end}}{{end}}' "$name" >"$out" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      gh_notice "job inspect failed: ${file}: $(head -n 1 "$out")"
      rm -f "$out"
      continue
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      gh_notice "registered ${line}"
    done <"$out"
    rm -f "$out"
  done
}

main() {
  local file failed=0 rc root="$ROOT"
  if [[ -n "${RECONCILE_ROOT:-}" ]]; then
    root="$RECONCILE_ROOT"
  fi
  cd "$root"

  if [[ -z "${NOMAD_ADDR:-}" ]]; then
    ci_error "NOMAD_ADDR is not set"
    exit 1
  fi

  local files=()
  mapfile -t files < <(find nomad_jobs -type f -name '*.nomad.hcl' | sort)
  if [[ "${#files[@]}" -eq 0 ]]; then
    ci_error "no job files under nomad_jobs/"
    exit 1
  fi

  # A status run does nothing else. Actions keeps only the first ten notices
  # of a step, so these would crowd out the reconcile's decrease notices.
  if [[ -n "${RECONCILE_STATUS:-}" ]]; then
    note_cluster_status "${files[@]}"
    exit 0
  fi

  load_decrease_declarations

  for file in "${files[@]}"; do
    # reconcile_one toggles set -e internally; an OR list keeps a non-zero
    # return from aborting the loop before the status is recorded.
    rc=0
    reconcile_one "$file" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      continue
    fi
    if [[ "$rc" -eq 10 ]]; then
      ci_error "stopped after deployment failure: ${file}"
      exit 1
    fi
    failed=1
  done

  exit "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
