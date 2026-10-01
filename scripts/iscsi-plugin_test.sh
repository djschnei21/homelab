#!/usr/bin/env bash
# Locks the Phase 3 plugin jobs and the volume specs the copy job consumes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTRL="$ROOT/nomad_jobs/plugins/democratic-csi-iscsi-controller.nomad.hcl"
NODE="$ROOT/nomad_jobs/plugins/democratic-csi-iscsi-nodes.nomad.hcl"
CA="$ROOT/nomad_jobs/plugins/files/nas2-ca.pem"

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

lacks() { ! grep -q -- "$2" "$1"; }

check "controller job name" grep -q '^job "democratic-csi-iscsi-controller"' "$CTRL"
check "node job name" grep -q '^job "democratic-csi-iscsi-nodes"' "$NODE"
check "controller is not privileged" lacks "$CTRL" "privileged"
check "controller uses https" grep -q 'protocol: https' "$CTRL"
check "controller uses port 443" grep -q 'port: 443' "$CTRL"
check "controller refuses insecure TLS" grep -q 'allowInsecure: false' "$CTRL"
check "controller points Node at the rendered CA" grep -q 'NODE_EXTRA_CA_CERTS = "${NOMAD_SECRETS_DIR}/nas2-ca.pem"' "$CTRL"
check "controller renders the repo CA file" grep -q 'file("nomad_jobs/plugins/files/nas2-ca.pem")' "$CTRL"
check "controller apiKey path is the task path" \
  grep -q 'nomadVar "nomad/jobs/democratic-csi-iscsi-controller/controller/plugin"' "$CTRL"
check "controller dataset parent" grep -q 'datasetParentName: homelab-general/nomad-csi$' "$CTRL"
check "controller snapshot parent is a sibling" \
  grep -q 'detachedSnapshotsDatasetParentName: homelab-general/nomad-csi-snapshots$' "$CTRL"
check "controller leaves zvols sparse" grep -q 'zvolEnableReservation: false' "$CTRL"
check "controller uses 4k extents" grep -q 'extentBlocksize: 4096' "$CTRL"
check "controller requires CHAP" grep -q 'targetGroupAuthType: CHAP' "$CTRL"
check "controller uses auth group 1" grep -q 'targetGroupAuthGroup: 1' "$CTRL"
check "node is a system job" grep -Eq 'type[[:space:]]+= "system"' "$NODE"
check "node is privileged" grep -Eq 'privileged[[:space:]]+= true' "$NODE"
check "node uses host network" grep -q 'network_mode = "host"' "$NODE"
check "node uses host IPC" grep -q 'ipc_mode     = "host"' "$NODE"
check "node bind-mounts the host root" grep -Eq 'target[[:space:]]+= "/host"' "$NODE"
check "node detects filesystems with blkid" \
  grep -q 'FILESYSTEM_TYPE_DETECTION_STRATEGY = "blkid"' "$NODE"
check "node updates one client at a time" grep -q 'max_parallel = 1' "$NODE"
check "node has no API key" lacks "$NODE" "apiKey"
check "node has no nomad variable" lacks "$NODE" "nomadVar"
check "node matches the extent and CHAP settings" bash -c 'grep -q "extentBlocksize: 4096" "$1" && grep -q "targetGroupAuthType: CHAP" "$1"' bash "$NODE"
check "CA placeholder is not a certificate" lacks "$CA" "BEGIN CERTIFICATE"
check "CA placeholder names nas2" grep -q '192.168.68.50' "$CA"

VOL="$ROOT/nomad_volumes/iscsi"
check "volume specs are sized" bash -c "! grep -R -q CAPACITY_PLACEHOLDER '$VOL'"
declare -A CAPACITY=(
  [bitcoin-chain]=1100GiB
  [electrs-index]=80GiB
  [prometheus-tsdb]=2GiB
  [albyhub-work]=1GiB
  [grafana-db]=1GiB
  [tailscale-state]=1GiB
)
for name in bitcoin-chain electrs-index albyhub-work prometheus-tsdb grafana-db tailscale-state; do
  file="$VOL/${name}.hcl"
  size=${CAPACITY[$name]}
  check "${name} exists" test -f "$file"
  check "${name} capacity_min" grep -q "capacity_min = \"${size}\"" "$file"
  check "${name} capacity_max matches" grep -q "capacity_max = \"${size}\"" "$file"
  check "${name} has no secrets" lacks "$file" "secrets"
  check "${name} is ext4" grep -q 'fs_type     = "ext4"' "$file"
  check "${name} is noatime" grep -q 'mount_flags = \["noatime"\]' "$file"
  check "${name} is single-node-writer" grep -q 'access_mode     = "single-node-writer"' "$file"
  check "${name} is a filesystem" grep -q 'attachment_mode = "file-system"' "$file"
done
check "bitcoin volumes are in bitcoin" bash -c "grep -Eq 'namespace[[:space:]]+= \"bitcoin\"' '$VOL/bitcoin-chain.hcl' '$VOL/electrs-index.hcl' '$VOL/albyhub-work.hcl'"
check "the other volumes are in default" bash -c "grep -Eq 'namespace[[:space:]]+= \"default\"' '$VOL/prometheus-tsdb.hcl' '$VOL/grafana-db.hcl' '$VOL/tailscale-state.hcl'"

SCRATCH="$ROOT/tests/storage/csi-scratch.hcl"
check "scratch is outside nomad_jobs" bash -c "[[ '$SCRATCH' != *nomad_jobs* ]]"
check "scratch is not a placeholder" lacks "$SCRATCH" "CAPACITY_PLACEHOLDER"
check "scratch has no secrets" lacks "$SCRATCH" "secrets"
check "holder is outside nomad_jobs" test -f "$ROOT/tests/storage/holder.nomad.hcl"
check "holder runs as non-root" grep -Eq 'user[[:space:]]+= "65534:65534"' "$ROOT/tests/storage/holder.nomad.hcl"
check "holder prestart chowns the mount" grep -q 'chown 65534:65534 /data' "$ROOT/tests/storage/holder.nomad.hcl"
check "holder prestart is not a sidecar" grep -q 'sidecar = false' "$ROOT/tests/storage/holder.nomad.hcl"
check "holder waits in the background" grep -q 'sleep 3600 &' "$ROOT/tests/storage/holder.nomad.hcl"
check "copy job is outside nomad_jobs" test -f "$ROOT/tests/storage/copy-volume.nomad.hcl"
check "copy job is batch" grep -Eq 'type[[:space:]]+= "batch"' "$ROOT/tests/storage/copy-volume.nomad.hcl"
check "copy job pins an rsync image" grep -q 'instrumentisto/rsync-ssh:alpine3.23-r3' "$ROOT/tests/storage/copy-volume.nomad.hcl"
check "copy job uses the cutover rsync flags" \
  grep -q 'rsync -aH --numeric-ids --delete --exclude=/lost+found --chown=' "$ROOT/tests/storage/copy-volume.nomad.hcl"
check "copy job can exclude the stale chain subtree" \
  grep -q 'extra_excludes' "$ROOT/tests/storage/copy-volume.nomad.hcl"
check "copy job joins excludes with commas" \
  grep -q 'join(",", var.extra_excludes)' "$ROOT/tests/storage/copy-volume.nomad.hcl"
check "readme lists the cutover owners" bash -c 'grep -q "65534:65534" "$1" && grep -q "472:0" "$1" && grep -q "chown=0:0" "$1" && grep -q "3001:3001" "$1" && grep -q "/bitcoin-data" "$1"' bash "$ROOT/tests/storage/README.md"
check "storage readme says why these jobs are not reconciled" \
  grep -q 'nomad_jobs' "$ROOT/tests/storage/README.md"

echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
