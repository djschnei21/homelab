#!/usr/bin/env bash
# Exercises scripts/nomad-volume-create.sh with a fake nomad. No cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/nomad-volume-create.sh"

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

assert_eq() {
  local got=$1 want=$2
  if [[ $got != "$want" ]]; then
    printf 'got:  %s\nwant: %s\n' "$got" "$want" >&2
    return 1
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/home/.nomad"

cat >"$WORK/bin/nomad" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} != volume || ${2:-} != create || -z ${3:-} ]]; then
  echo "unexpected nomad invocation: $*" >&2
  exit 97
fi
stat -c '%a' "$3" >"${NOMAD_MODE_FILE:?}"
cp "$3" "${NOMAD_SPEC_COPY:?}"
printf '%s\n' "$*" >"${NOMAD_ARGS_FILE:?}"
EOF
chmod 755 "$WORK/bin/nomad"

SPEC="$WORK/scratch.hcl"
printf '%s\n' 'id = "csi-scratch"' 'namespace = "default"' >"$SPEC"

write_chap() {
  local mode=$1 body=$2
  printf '%s\n' "$body" >"$WORK/home/.nomad/iscsi-chap.env"
  chmod "$mode" "$WORK/home/.nomad/iscsi-chap.env"
}

run_create() {
  local rc
  set +e
  HOME="$WORK/home" TMPDIR="$WORK/tmp" PATH="$WORK/bin:$PATH" \
    NOMAD_MODE_FILE="$WORK/mode" NOMAD_SPEC_COPY="$WORK/spec-copy" NOMAD_ARGS_FILE="$WORK/args" \
    bash "$SCRIPT" "$SPEC" >"$WORK/out" 2>"$WORK/err"
  rc=$?
  set -e
  printf '%s' "$rc"
}

write_chap 600 $'ISCSI_CHAP_USER="chap-user"\nISCSI_CHAP_SECRET=secret"quote\\\n# comment\n'
rc=$(run_create)
check "create exits 0" assert_eq "$rc" "0"
check "temp spec was mode 0600" assert_eq "$(cat "$WORK/mode")" "600"
check "temp spec is removed" assert_eq "$(find "$WORK/tmp" -type f | wc -l | tr -d ' ')" "0"
check "nomad saw volume create" grep -q '^volume create ' "$WORK/args"
spec_body=$(cat "$WORK/spec-copy")
check "secrets use the node-db CHAP keys" grep -q 'node-db.node.session.auth.authmethod" = "CHAP"' <<<"$spec_body"
check "username is unquoted from the env file" grep -q 'node-db.node.session.auth.username" = "chap-user"' <<<"$spec_body"
want=$'  "node-db.node.session.auth.password" = "secret\\"quote\\\\"'
check "secret quotes and backslashes are escaped" grep -F -q "$want" "$WORK/spec-copy"
check "stdout does not contain the secret" bash -c "! grep -q 'secret' '$WORK/out'"
check "stderr does not contain the secret" bash -c "! grep -q 'secret' '$WORK/err'"

write_chap 644 $'ISCSI_CHAP_USER=u\nISCSI_CHAP_SECRET=s\n'
check "mode 0644 is refused" assert_eq "$(run_create)" "1"

write_chap 600 $'ISCSI_CHAP_USER=u\n'
check "a missing secret is refused" assert_eq "$(run_create)" "1"

write_chap 600 "$(printf 'ISCSI_CHAP_USER=$(touch %s/pwned)\nISCSI_CHAP_SECRET=s\n' "$WORK")"
rc=$(run_create)
check "a shell snippet is not executed" test ! -e "$WORK/pwned"
check "literal snippet still creates" assert_eq "$rc" "0"
check "the shell snippet is stored literally" grep -F -q "touch ${WORK}/pwned" "$WORK/spec-copy"

printf '%s\n' 'id = "bitcoin-chain"' '# CAPACITY_PLACEHOLDER' >"$SPEC"
write_chap 600 $'ISCSI_CHAP_USER=u\nISCSI_CHAP_SECRET=s\n'
check "a capacity placeholder is refused" assert_eq "$(run_create)" "1"
set +e
HOME="$WORK/home" TMPDIR="$WORK/tmp" PATH="$WORK/bin:$PATH" NOMAD_VOLUME_ALLOW_PLACEHOLDER=1 \
  NOMAD_MODE_FILE="$WORK/mode" NOMAD_SPEC_COPY="$WORK/spec-copy" NOMAD_ARGS_FILE="$WORK/args" \
  bash "$SCRIPT" "$SPEC" >"$WORK/out" 2>"$WORK/err"
override_rc=$?
set -e
check "placeholder override reaches nomad" assert_eq "$override_rc" "0"

printf '%s\n' 'secrets {' '  already = "no"' '}' >"$SPEC"
check "an existing secrets block is refused" assert_eq "$(run_create)" "1"

if command -v shellcheck >/dev/null 2>&1; then
  check "volume create script is shellcheck clean" shellcheck "$SCRIPT"
else
  echo "skip shellcheck: not installed"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
