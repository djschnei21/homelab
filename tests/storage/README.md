# Storage proofs and the copy job

These files stay out of `nomad_jobs/`. Reconcile submits every `nomad_jobs/**/*.nomad.hcl` on main. A holder or a copy job there would be planned on every reconcile, including while a cutover has a group scaled to zero.

Run them by hand from the repo root. Submit the copy and holder jobs with the bootstrap token. `storage-admin` creates volumes, scales groups to 0, and stops allocations. It cannot submit jobs: a submitted job's workload identity reads every variable at `nomad/jobs/<job>/<group>/<task>`.

`csi-scratch.hcl` is the Phase 4 ext4 volume (1 GiB). Create it with `scripts/nomad-volume-create.sh`. The six specs under `nomad_volumes/iscsi/` already have their preflight `capacity_min` (and the same `capacity_max`).

`holder.nomad.hcl` chowns the mount root to `65534:65534` in a non-sidecar prestart, then a `65534` task writes `/data/marker` once and appends `/data/visits`. A fresh ext4 root is `root:root` `0755`, so the writer cannot create the marker until that chown. `-var shutdown_delay_seconds=180` sleeps in the SIGTERM trap. The trap is armed around `sleep 3600 & wait $!`, so the signal is not stuck behind an hour of foreground sleep. `kill_timeout` is that delay plus 15 seconds, which needs the client `max_kill_timeout` from the client-prep PR before a 3 minute drain proof. `-var fence=true` adds `disconnect { lost_after = "12h", replace = false, reconcile = "keep_original" }`. `-var target_node=pinode3` pins the alloc. Do not drain a client to move it.

`copy-volume.nomad.hcl` claims `source_volume` read-only and `dest_volume` read-write. The default source access mode is `multi-node-single-writer`, which chain, electrs, and tailscale register, so those copies can run beside the live writer and again after the stop. Prometheus, Grafana, and Alby only register `single-node-writer`, so their copies pass that mode and run once, after the writer group is scaled to 0. It runs:

```
rsync -aH --numeric-ids --delete --exclude=/lost+found --chown=<uid>:<gid>
```

from `instrumentisto/rsync-ssh:alpine3.23-r3`. `-var verify=true` is `--dry-run --itemize-changes` and exits non-zero if rsync lists anything. `-var checksum=true` adds `--checksum` on that dry run. `-var dest_subdir=data` copies into that directory so Prometheus can keep its TSDB off `lost+found`. `-var 'extra_excludes=["/bitcoin-data"]'` adds excludes. Patterns are joined with commas for the task env, so a pattern cannot contain a comma or start with a dash. The chain source has a stale `bitcoin-data` directory at its root.

Owners and the commands for each cutover, from the repo root:

```bash
# Prometheus. Single pass, after the writer group is scaled to 0.
# prometheus-data is single-node-writer only. TSDB at data/, not the volume root.
nomad job run -namespace=default \
  -var namespace=default \
  -var source_volume=prometheus-data \
  -var source_access_mode=single-node-writer \
  -var dest_volume=prometheus-tsdb \
  -var chown=65534:65534 \
  -var dest_subdir=data \
  tests/storage/copy-volume.nomad.hcl

# Grafana. Single pass, after the writer group is scaled to 0.
# grafana-data is single-node-writer only.
nomad job run -namespace=default \
  -var namespace=default \
  -var source_volume=grafana-data \
  -var source_access_mode=single-node-writer \
  -var dest_volume=grafana-db \
  -var chown=472:0 \
  tests/storage/copy-volume.nomad.hcl

# Tailscale. tailscale-proxy-state is multi-node-single-writer, so the default stands.
nomad job run -namespace=default \
  -var namespace=default \
  -var source_volume=tailscale-proxy-state \
  -var dest_volume=tailscale-state \
  -var chown=0:0 \
  tests/storage/copy-volume.nomad.hcl

# Alby. Single pass, after the writer group is scaled to 0.
# albyhub-data is single-node-writer only.
nomad job run -namespace=bitcoin \
  -var namespace=bitcoin \
  -var source_volume=albyhub-data \
  -var source_access_mode=single-node-writer \
  -var dest_volume=albyhub-work \
  -var chown=0:0 \
  tests/storage/copy-volume.nomad.hcl

# Electrs index. Default multi-node-single-writer: pass 1 beside the live writer, pass 2 after the stop.
nomad job run -namespace=bitcoin \
  -var namespace=bitcoin \
  -var source_volume=electrs-data \
  -var dest_volume=electrs-index \
  -var chown=3001:3001 \
  tests/storage/copy-volume.nomad.hcl

# Chain. Same default: pass 1 beside the live writer, pass 2 after the stop.
# Skip the stale bitcoin-data directory at the source root.
# The bitcoin chain export does not map root, so that copy passes task_user=3001:3001.
nomad job run -namespace=bitcoin \
  -var namespace=bitcoin \
  -var source_volume=bitcoin-data \
  -var dest_volume=bitcoin-chain \
  -var chown=3001:3001 \
  -var task_user=3001:3001 \
  -var 'extra_excludes=["/bitcoin-data"]' \
  tests/storage/copy-volume.nomad.hcl
```

Add `-var verify=true -var checksum=true` for the dry run on everything except the chain. The chain verify is `-var verify=true` without checksum.
