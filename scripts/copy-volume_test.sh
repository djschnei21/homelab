#!/usr/bin/env bash
# Runs the copy job's rsync script against local directories.
# Uses rsync when it is installed, and a small stand-in otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB="$ROOT/tests/storage/copy-volume.nomad.hcl"

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

# One HCL pass: $$ becomes $.
awk 'f && /^COPYEOF$/ { exit } f; /<<COPYEOF$/ { f = 1 }' "$JOB" | sed 's/\$\${/${/g' > /tmp/copy-volume.sh
chmod 755 /tmp/copy-volume.sh

if ! command -v rsync >/dev/null 2>&1; then
  sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y rsync >/dev/null 2>&1 || true
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
USE_SUDO=0
if command -v rsync >/dev/null 2>&1; then
  USE_SUDO=1
else
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/rsync" <<'PY'
#!/usr/bin/env python3
import filecmp, hashlib, os, sys

args = sys.argv[1:]
dry = itemize = checksum = delete = False
excludes, paths = [], []
i = 0
while i < len(args):
    a = args[i]
    if a in ("-aH", "-a", "-H", "--numeric-ids"):
        i += 1
    elif a == "--delete":
        delete = True
        i += 1
    elif a == "--dry-run":
        dry = True
        i += 1
    elif a == "--itemize-changes":
        itemize = True
        i += 1
    elif a == "--checksum":
        checksum = True
        i += 1
    elif a.startswith("--exclude="):
        excludes.append(a.split("=", 1)[1])
        i += 1
    elif a.startswith("--chown="):
        i += 1
    elif a.startswith("-"):
        sys.stderr.write("unsupported %s\n" % a)
        sys.exit(2)
    else:
        paths.append(a)
        i += 1
if len(paths) != 2:
    sys.exit(2)
src, dest = (p.rstrip("/") for p in paths)

def excluded(rel):
    for pat in excludes:
        p = pat.lstrip("/")
        if rel == p or rel.startswith(p + "/"):
            return True
    return False

def files(root):
    found = []
    if not os.path.isdir(root):
        return found
    for dirpath, dirnames, names in os.walk(root):
        dirnames[:] = [d for d in dirnames if not excluded(os.path.relpath(os.path.join(dirpath, d), root))]
        for name in names:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if not excluded(rel):
                found.append(rel)
    return found

def differs(rel):
    s, d = os.path.join(src, rel), os.path.join(dest, rel)
    if not os.path.exists(d):
        return True
    if checksum:
        digest = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
        return digest(s) != digest(d)
    return not filecmp.cmp(s, d, shallow=False)

src_files = files(src)
changes = []
for rel in src_files:
    if differs(rel):
        changes.append(">f+++++++++ " + rel)
if delete:
    for rel in files(dest):
        if rel not in src_files:
            changes.append("*deleting " + rel)
if dry:
    if itemize:
        sys.stdout.write("".join(line + "\n" for line in changes))
    sys.exit(0)
for rel in src_files:
    target = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    open(target, "wb").write(open(os.path.join(src, rel), "rb").read())
if delete:
    for rel in files(dest):
        if rel not in src_files:
            os.remove(os.path.join(dest, rel))
PY
  chmod 755 "$WORK/bin/rsync"
  PATH="$WORK/bin:$PATH"
fi

mkdir -p "$WORK/src" "$WORK/dest"
printf 'same\n' >"$WORK/src/file"
uid=$(id -u)
gid=$(id -g)

run_copy() {
  local rc
  set +e
  if [[ $USE_SUDO == 1 ]]; then
    sudo -n -E \
      SRC_DIR="$WORK/src" DEST_DIR="$WORK/dest" \
      CHOWN="${CHOWN:-${uid}:${gid}}" DEST_SUBDIR="${DEST_SUBDIR:-}" \
      VERIFY="${VERIFY:-false}" CHECKSUM="${CHECKSUM:-false}" \
      EXTRA_EXCLUDES="${EXTRA_EXCLUDES:-}" \
      /bin/sh /tmp/copy-volume.sh >"$WORK/out" 2>"$WORK/err"
  else
    SRC_DIR="$WORK/src" DEST_DIR="$WORK/dest" \
      CHOWN="${CHOWN:-${uid}:${gid}}" DEST_SUBDIR="${DEST_SUBDIR:-}" \
      VERIFY="${VERIFY:-false}" CHECKSUM="${CHECKSUM:-false}" \
      EXTRA_EXCLUDES="${EXTRA_EXCLUDES:-}" \
      /bin/sh /tmp/copy-volume.sh >"$WORK/out" 2>"$WORK/err"
  fi
  rc=$?
  set -e
  printf '%s' "$rc"
}

show() { if [[ $USE_SUDO == 1 ]]; then sudo cat "$1"; else cat "$1"; fi; }

check "a real copy exits 0" assert_eq "$(VERIFY=false CHECKSUM=false DEST_SUBDIR=sub EXTRA_EXCLUDES= run_copy)" "0"
check "copy wrote the file" assert_eq "$(show "$WORK/dest/sub/file")" "same"
check "verify is quiet when the trees match" assert_eq "$(VERIFY=true CHECKSUM=true DEST_SUBDIR=sub EXTRA_EXCLUDES= run_copy)" "0"
check "a quiet verify prints nothing" assert_eq "$(cat "$WORK/out")" ""

if [[ $USE_SUDO == 1 ]]; then
  printf 'changed\n' | sudo tee "$WORK/dest/sub/file" >/dev/null
else
  printf 'changed\n' >"$WORK/dest/sub/file"
fi
rc=$(VERIFY=true CHECKSUM=true DEST_SUBDIR=sub EXTRA_EXCLUDES= run_copy)
check "checksum verify fails after a content change" bash -c "[[ '$rc' != 0 ]]"
check "checksum verify lists the change" grep -q 'file' "$WORK/out"

check "copy restores the file" assert_eq "$(VERIFY=false DEST_SUBDIR=sub EXTRA_EXCLUDES= run_copy)" "0"
if [[ $USE_SUDO == 1 ]]; then
  sudo mkdir -p "$WORK/dest/lost+found"
  printf 'extra\n' | sudo tee "$WORK/dest/sub/extra" >/dev/null
  printf 'keep\n' | sudo tee "$WORK/dest/lost+found/keep" >/dev/null
else
  mkdir -p "$WORK/dest/lost+found"
  printf 'extra\n' >"$WORK/dest/sub/extra"
  printf 'keep\n' >"$WORK/dest/lost+found/keep"
fi
check "copy deletes extras and keeps lost+found" assert_eq "$(VERIFY=false DEST_SUBDIR=sub EXTRA_EXCLUDES= run_copy)" "0"
check "extra file was deleted" test ! -e "$WORK/dest/sub/extra"
check "lost+found outside the subdir remains" test -f "$WORK/dest/lost+found/keep"

if [[ $USE_SUDO == 1 ]]; then sudo rm -rf "$WORK/dest"; else rm -rf "$WORK/dest"; fi
mkdir -p "$WORK/dest/lost+found" "$WORK/src"
printf 'root\n' >"$WORK/src/rootfile"
printf 'keep\n' >"$WORK/dest/lost+found/keep"
if [[ $USE_SUDO == 1 ]]; then sudo chown -R root:root "$WORK/dest" || true; fi
check "root copy exits 0" assert_eq "$(VERIFY=false DEST_SUBDIR= EXTRA_EXCLUDES= run_copy)" "0"
check "root copy keeps lost+found" test -f "$WORK/dest/lost+found/keep"
check "root copy wrote the file" test -f "$WORK/dest/rootfile"

mkdir -p "$WORK/src/bitcoin-data" "$WORK/src/blocks"
printf 'stale\n' >"$WORK/src/bitcoin-data/stale"
printf 'blk\n' >"$WORK/src/blocks/blk"
if [[ $USE_SUDO == 1 ]]; then sudo rm -rf "$WORK/dest"; else rm -rf "$WORK/dest"; fi
mkdir -p "$WORK/dest"
check "chain exclude copy exits 0" assert_eq "$(VERIFY=false DEST_SUBDIR= EXTRA_EXCLUDES=/bitcoin-data run_copy)" "0"
check "stale bitcoin-data subtree is excluded" test ! -e "$WORK/dest/bitcoin-data"
check "other chain files are copied" test -f "$WORK/dest/blocks/blk"

check "chown with a flag is refused" assert_eq "$(CHOWN='--delete' VERIFY=false DEST_SUBDIR= EXTRA_EXCLUDES= run_copy)" "1"
check "a parent dest subdir is refused" assert_eq "$(VERIFY=false DEST_SUBDIR=../x EXTRA_EXCLUDES= run_copy)" "1"
check "an exclude flag is refused" assert_eq "$(VERIFY=false DEST_SUBDIR= EXTRA_EXCLUDES=--delete run_copy)" "1"

if command -v shellcheck >/dev/null 2>&1; then
  check "copy script is shellcheck clean" shellcheck /tmp/copy-volume.sh
else
  echo "skip shellcheck: not installed"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
