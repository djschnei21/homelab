# Storage proofs and the copy job

These files stay out of `nomad_jobs/`. Reconcile submits every `nomad_jobs/**/*.nomad.hcl` on main. A holder or a copy job there would be planned on every reconcile, including while a cutover has a group scaled to zero.

Run them by hand from the repo root, with `NOMAD_ADDR` and a storage-admin token.

`csi-scratch.hcl` is the Phase 4 ext4 volume (1 GiB). Create it with `scripts/nomad-volume-create.sh`. The six specs under `nomad_volumes/iscsi/` already have their preflight `capacity_min` (and the same `capacity_max`).

`holder.nomad.hcl` is a non-root task (`65534:65534`) that writes `/data/marker` once and appends `/data/visits`. The fresh ext4 root is owned by root, so chown the mount to `65534:65534` before the holder (the copy job can do that). `-var shutdown_delay_seconds=180` sleeps in the SIGTERM trap. `kill_timeout` is that delay plus 15 seconds, which needs the client `max_kill_timeout` from the client-prep PR before a 3 minute drain proof. `-var fence=true` adds `disconnect { lost_after = "12h", replace = false, reconcile = "keep_original" }`. `-var target_node=pinode3` pins the alloc. Do not drain a client to move it.

`copy-volume.nomad.hcl` claims `source_volume` read-only (`multi-node-single-writer` by default, so pass 1 can run beside the live writer) and `dest_volume` read-write. It runs:

```
rsync -aH --numeric-ids --delete --exclude=/lost+found --chown=<uid>:<gid>
```

from `instrumentisto/rsync-ssh:alpine3.23-r3`. `-var verify=true` is `--dry-run --itemize-changes` and exits non-zero if rsync lists anything. `-var checksum=true` adds `--checksum` on that dry run. `-var dest_subdir=data` copies into that directory so Prometheus can keep its TSDB off `lost+found`. `-var 'extra_excludes=["/bitcoin-data"]'` adds excludes; the chain source has a stale `bitcoin-data` directory at its root.

Owners and the commands for each cutover, from the repo root:

```bash
# Prometheus. TSDB at data/, not the volume root.
nomad job run -namespace=default \
  -var namespace=default \
  -var source_volume=prometheus-data \
  -var dest_volume=prometheus-tsdb \
  -var chown=65534:65534 \
  -var dest_subdir=data \
  tests/storage/copy-volume.nomad.hcl

# Grafana
nomad job run -namespace=default \
  -var namespace=default \
  -var source_volume=grafana-data \
  -var dest_volume=grafana-db \
  -var chown=472:0 \
  tests/storage/copy-volume.nomad.hcl

# Tailscale
nomad job run -namespace=default \
  -var namespace=default \
  -var source_volume=tailscale-proxy-state \
  -var dest_volume=tailscale-state \
  -var chown=0:0 \
  tests/storage/copy-volume.nomad.hcl

# Alby
nomad job run -namespace=bitcoin \
  -var namespace=bitcoin \
  -var source_volume=albyhub-data \
  -var dest_volume=albyhub-work \
  -var chown=0:0 \
  tests/storage/copy-volume.nomad.hcl

# Electrs index
nomad job run -namespace=bitcoin \
  -var namespace=bitcoin \
  -var source_volume=electrs-data \
  -var dest_volume=electrs-index \
  -var chown=3001:3001 \
  tests/storage/copy-volume.nomad.hcl

# Chain. Skip the stale bitcoin-data directory at the source root.
nomad job run -namespace=bitcoin \
  -var namespace=bitcoin \
  -var source_volume=bitcoin-data \
  -var dest_volume=bitcoin-chain \
  -var chown=3001:3001 \
  -var 'extra_excludes=["/bitcoin-data"]' \
  tests/storage/copy-volume.nomad.hcl
```

Add `-var verify=true -var checksum=true` for the dry run on everything except the chain. The chain verify is `-var verify=true` without checksum.
