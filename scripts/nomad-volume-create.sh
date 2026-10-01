#!/usr/bin/env bash
# Create one CSI volume, adding iSCSI CHAP secrets from a 0600 env file.
# The spec in git stays free of secrets. A spec marked CAPACITY_PLACEHOLDER
# is refused until the preflight sizes replace it.
set -euo pipefail

if [[ $# -ne 1 || -z ${1:-} ]]; then
  echo "usage: nomad-volume-create.sh <volume-spec>" >&2
  exit 1
fi

spec=$1
chap_file=${ISCSI_CHAP_FILE:-${HOME}/.nomad/iscsi-chap.env}

if [[ ! -f $spec || -L $spec ]]; then
  echo "volume spec must be a regular file: ${spec}" >&2
  exit 1
fi

if grep -q 'CAPACITY_PLACEHOLDER' "$spec" && [[ ${NOMAD_VOLUME_ALLOW_PLACEHOLDER:-} != 1 ]]; then
  echo "refusing ${spec}: capacity is still the preflight placeholder" >&2
  exit 1
fi

if grep -Eq '^[[:space:]]*secrets[[:space:]]*\{' "$spec"; then
  echo "volume spec must not contain a secrets block: ${spec}" >&2
  exit 1
fi

if [[ ! -f $chap_file || -L $chap_file ]]; then
  echo "CHAP file must be a regular file: ${chap_file}" >&2
  exit 1
fi

mode=$(stat -c '%a' "$chap_file")
if [[ $mode != 600 ]]; then
  echo "CHAP file must be mode 0600: ${chap_file}" >&2
  exit 1
fi

chap_user=
chap_secret=
while IFS= read -r line || [[ -n $line ]]; do
  case $line in
    '' | \#*) continue ;;
    ISCSI_CHAP_USER=*) chap_user=${line#ISCSI_CHAP_USER=} ;;
    ISCSI_CHAP_SECRET=*) chap_secret=${line#ISCSI_CHAP_SECRET=} ;;
    *)
      echo "unexpected line in CHAP file" >&2
      exit 1
      ;;
  esac
done <"$chap_file"

unquote() {
  local value=$1
  if [[ $value == \"*\" && $value == *\" ]]; then
    value=${value#\"}
    value=${value%\"}
  elif [[ $value == \'*\' && $value == *\' ]]; then
    value=${value#\'}
    value=${value%\'}
  fi
  printf '%s' "$value"
}

chap_user=$(unquote "$chap_user")
chap_secret=$(unquote "$chap_secret")

if [[ -z $chap_user || -z $chap_secret ]]; then
  echo "CHAP file must set ISCSI_CHAP_USER and ISCSI_CHAP_SECRET" >&2
  exit 1
fi

hcl_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

umask 077
tmp=$(mktemp "${TMPDIR:-/tmp}/nomad-volume.XXXXXX")
trap 'rm -f "$tmp"' EXIT

cat "$spec" >"$tmp"
{
  printf '\n'
  printf 'secrets {\n'
  printf '  "node-db.node.session.auth.authmethod" = "CHAP"\n'
  printf '  "node-db.node.session.auth.username" = "%s"\n' "$(hcl_escape "$chap_user")"
  printf '  "node-db.node.session.auth.password" = "%s"\n' "$(hcl_escape "$chap_secret")"
  printf '}\n'
} >>"$tmp"

nomad volume create "$tmp"
