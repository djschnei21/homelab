# AGENTS.md

## Project Overview

This is a Bitcoin infrastructure homelab using HashiCorp Nomad to orchestrate Bitcoin and related services on a Raspberry Pi cluster.

## Architecture

**Cluster Topology:**
- 4 Raspberry Pi nodes in datacenter "homelab"
- 1 Nomad server (pinode1) with single-node bootstrap
- 3 Nomad clients (pinode2, pinode3, pinode4) running Docker

**Services:**
- Bitcoin Core full node with RPC/P2P and transaction indexing
- Electrs - Electrum protocol server (discovers Bitcoin via Nomad service templates)
- Alby Hub - Lightning wallet manager with PostgreSQL backend
- Prometheus + Grafana - Metrics collection and visualization (default namespace)
- Node Exporter - OS-level metrics from each client node (system job)

**Storage:**
- iSCSI zvols under `homelab-general/nomad-csi` on TrueNAS (nas2.local / 192.168.68.50)
- PostgreSQL database for Alby Hub on the same server

## Repository Structure

- `bootstrap/` - Ansible playbooks and roles for cluster initialization
  - `inventory.yml` - Node definitions
  - `nomad/roles/` - common, nomad_server, nomad_client roles
  - `nomad/playbooks/` - Operational playbooks (patching, maintenance)
- `nomad_jobs/` - Nomad job definitions (HCL)
  - `bitcoin/` - Bitcoin-related service jobs
  - `observability/` - Prometheus, Grafana, and node-exporter jobs
  - `plugins/` - democratic-csi iSCSI controller and node plugin jobs
- `nomad_acl/policies/` - Least-privilege ACL policies for CI tokens
- `nomad_namespaces/` - Namespace definitions (bitcoin-ns)
- `nomad_volumes/` - iSCSI volume specs in `iscsi/`

## Commands

Nomad server runs on pinode1. Set the address:
```bash
export NOMAD_ADDR=http://pinode1.local:4646
```

With ACLs enabled, every command also needs a token. The anonymous token gets nothing.
```bash
export NOMAD_TOKEN="$(cat ~/.nomad/<name>.token)"   # file holds only the secret ID
```
Policies live in `nomad_acl/policies/`; each file's header has its apply and token-create
commands. `dan-ui` is Dan's read-plus-alloc-lifecycle UI token. CI reads
`$HOME/.nomad/reconcile.token` (reconcile) and `$HOME/.nomad/patch.token`
(patch workflows) on the runner and runs without a token when the file is absent. The
Ansible playbooks pass `NOMAD_TOKEN` to the `nomad` commands they run on the Pis.

Reconcile CI refuses a plan that lowers `MemoryMB`, `MemoryMaxMB` (including removing
`memory_max`), or `CPU` unless the job is declared, and refuses an image downgrade even
then. Declare it on its own line in a commit message on the PR branch, not the PR body,
which never reaches main. Only commits in the pushed range count. A squash commit's body
is the branch's commit messages, so keep the line if you edit the squash message. A
manual run takes the same job list in the `allow_resource_decrease` input.
```text
Allow-Resource-Decrease: bitcoin-stack, prometheus
```

Memory oversubscription is enabled
(`nomad operator scheduler set-config -memory-oversubscription=true`, bootstrap
token). `memory` is the reservation the scheduler has to place. `memory_max` is
the cgroup ceiling (`memory.low` is the reservation, `memory.max` is the ceiling).
Size `memory` from the observed RSS peak and set `memory_max` only where the task
needs cache or headroom above that peak. A job with `memory_max` is rejected
while oversubscription is off. Turning it on does nothing to a task that leaves
`memory_max` unset.

bitcoind reserves 4096 MB and may use 6144 MB (`-dbcache=1024` is pinned; host
RAM would pick the same number). In the normal layout each other client keeps
enough unreserved memory for that 4096 MB reservation, so a drain can move
bitcoind. electrs reserves 1024 MB with a 2048 MB ceiling. Prometheus reserves
256 MB with a 512 MB ceiling. The mempool backend
reserves 2048 MB with a 3072 MB ceiling. MariaDB reserves 256 MB, the frontend
64 MB, and Alby Hub 1280 MB with a 2048 MB ceiling. Grafana reserves 512 MB
with a 768 MB ceiling.

**Deploy a Nomad job:**
```bash
nomad job run -namespace=bitcoin nomad_jobs/bitcoin/bitcoin-stack.nomad.hcl
```

**Check job status:**
```bash
nomad job status -namespace=bitcoin <job-name>
```

**View job logs:**
```bash
nomad alloc logs <alloc-id>
```

**Plan changes before deploy:**
```bash
nomad job plan -namespace=bitcoin nomad_jobs/bitcoin/bitcoin-stack.nomad.hcl
```

**Restart a job (re-pulls image):**
```bash
nomad job restart -namespace=bitcoin bitcoin-stack
```

**Bootstrap cluster (Ansible):**
```bash
cd bootstrap/nomad && ansible-playbook -i ../inventory.yml nomad_cluster.yml
```

TrueNAS iSCSI disks report an 8 MB optimal I/O size, and the kernel then sets
`read_ahead_kb` to 16384. LevelDB does not use `MADV_RANDOM`, so one fault can
pull 16 MB. The client role writes `99-truenas-iscsi-readahead.rules` for
`ID_VENDOR=TrueNAS` and `ID_MODEL=iSCSI_Disk`, and `iscsi_read_ahead_kb`
defaults to 128. Apply only that work with:

```bash
cd bootstrap/nomad && ansible-playbook -i ../inventory.yml nomad_cluster.yml --tags iscsi_readahead
```

That tag installs the rule and runs `udevadm trigger` for block devices. It
does not notify Restart Nomad or Restart iscsid, and it does not install
Docker or Nomad, so those restarts cannot run. A full playbook run still
restarts Nomad when `client.hcl` changes.

## Key Patterns

- Services discover each other via Nomad service templates using `nomadService` lookups
- Secrets stored in Nomad variables and accessed via `nomadVar` at the consuming task's path,
  `nomad/jobs/<job>/<group>/<task>`. A workload identity reads only its job, group, and task
  paths without a policy, and a job or group path is readable by every task under it.
- All services use bridge networking with explicit port mappings
- Volumes are single-node-writer ext4 filesystems on iSCSI
- Jobs define resource constraints (memory/CPU) and health checks
- Use pinned image versions (e.g., `bitcoin:30.2`), not `latest`

## Forcing Job Updates

Jobs include a `meta.version` field. Nomad deduplicates identical jobs, so re-submitting
the same HCL won't create a new version. To force a new job version:

1. Bump `meta.version` in the job file
2. Run `nomad job run -namespace=bitcoin <job>.nomad.hcl`

This is useful when you need to update the job definition stored in Nomad (e.g., after
cleaning up comments) without changing the functional config.

## Cluster Maintenance

**Patch all nodes (OS, Nomad, Docker):**
```bash
cd bootstrap/nomad && ansible-playbook -i ../inventory.yml playbooks/patch_cluster.yml
```

The weekly run is the homelab-agent user timer `homelab-patch-dispatch.timer` at Monday 00:00 America/New_York. It dispatches `patch-infra.yml` on `main`. There is no GitHub cron; a `schedule:` trigger must not be added back.

The playbook handles rolling updates safely:
1. Pre-flight check verifies cluster health
2. Clients patched one-by-one: drain (15m deadline) → apt upgrade → reboot if needed → rejoin
3. Server patched last with health verification

Nodes only reboot when `/var/run/reboot-required` exists or packages changed.

## Rebalancing Jobs

After rolling updates or node maintenance, jobs may end up unevenly distributed. The cluster
uses the `spread` scheduler algorithm, but it only applies when placing new allocations.

To rebalance jobs across nodes:

1. Get the running allocation ID for each job:
   ```bash
   nomad job status -namespace=bitcoin <job-name> | grep "run.*running"
   ```

2. Stop each allocation to force rescheduling:
   ```bash
   nomad alloc stop -namespace=bitcoin <alloc-id>
   ```

The scheduler will place new allocations using the spread algorithm. This is disruptive
(brief downtime per job) so only run when rebalancing is needed.

Note: `nomad job eval -force-reschedule` does NOT move healthy allocations. You must
use `nomad alloc stop` to force actual rescheduling.

## Storage

Volumes are iSCSI zvols under `homelab-general/nomad-csi` on TrueNAS
(nas2.local / 192.168.68.50). Create one with `scripts/nomad-volume-create.sh`
from `nomad_volumes/iscsi/*.hcl`. Use a 24h storage-admin token. The policy and
the mint command are in `nomad_acl/policies/storage-admin.hcl`. CHAP secrets
live in `~/.nomad/iscsi-chap.env` on homelab-agent (mode 0600). The script
writes them into a temporary spec. The files in git have none.

```bash
scripts/nomad-volume-create.sh nomad_volumes/iscsi/<name>.hcl
```

`mempool-data` is 10 GiB in the bitcoin namespace, mounted at `/data` by
MariaDB (`--datadir=/data/mysql`) and the mempool backend
(`MEMPOOL_CACHE_DIR=/data/cache`). `await-services` creates `/data/cache` as
`1000:0` before the backend starts. The group has no disconnect fence; a lost
volume is rebuilt by re-indexing. The first start on a new volume re-indexes
about 11,000 blocks once. A later backend restart should come back in sync
without that re-index.

## NAS maintenance

Leave the iSCSI consumers running across a short NAS reboot. I/O pauses and
resumes. A planned reboot of a few minutes is inside the 600s `iscsid`
`replacement_timeout`. Stopping bitcoind takes Electrs and Alby down for
longer than the reboot. `-persistmempool=0` means bitcoind does not spend
hours reloading `mempool.dat`; Alby's fee estimates return once Electrs can
call `estimatesmartfee`. An outage past 600s becomes ext4 I/O errors. A NAS
reboot takes cluster DNS (AdGuard) down with it.

A session revalidation can put `read_ahead_kb` back to 16384 until udev runs
again. After the NAS is up, on each client:

```bash
grep -H . /sys/block/sd*/queue/read_ahead_kb
```

TrueNAS disks should read 128. If one reads 16384, reload and trigger block
devices only. Do not restart Nomad or Docker to apply it.

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --action=change --subsystem-match=block --type=devices
```

Scale these groups to 0 only when the outage will exceed 600s. `bitcoin-stack`
is in `bitcoin`. `prometheus` and `tailscale-proxy` are in `default`. Scale
the same groups back to 1 after the NAS is up.

```bash
nomad job scale -namespace=bitcoin bitcoin-stack bitcoin 0
nomad job scale -namespace=bitcoin bitcoin-stack electrs 0
nomad job scale -namespace=bitcoin bitcoin-stack mempool 0
nomad job scale -namespace=bitcoin bitcoin-stack albyhub 0
nomad job scale -namespace=default prometheus prometheus 0
nomad job scale -namespace=default prometheus grafana 0
nomad job scale -namespace=default tailscale-proxy proxy 0
```

Do not upgrade TrueNAS to 26 until democratic-csi ships WebSocket (JSON-RPC)
support. v1.9.5 is REST-only, and TrueNAS 25.10 REST needs the FULL_ADMIN
`nomad-csi` key.

Dead-client failover for the fenced groups (`bitcoin`, `albyhub`): confirm the
Pi is powered off, then purge that node.

```bash
nomad node purge <node-id>
```

When bitcoind was stopped or moved, Alby's LDK will not sync until Electrs fee
estimates work. `-persistmempool=0` keeps that wait to minutes, not a mempool
import. Restart the `albyhub` task if LDK is still down after estimates work.

```bash
nomad alloc restart -namespace=bitcoin -task albyhub <alloc-id>
```
