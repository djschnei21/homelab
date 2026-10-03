# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
commands. CI reads `$HOME/.nomad/reconcile.token` (reconcile) and `$HOME/.nomad/patch.token`
(patch workflows) on the runner and runs without a token when the file is absent. The
Ansible playbooks pass `NOMAD_TOKEN` to the `nomad` commands they run on the Pis.

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

## NAS maintenance

Before a planned NAS reboot, scale every group of the iSCSI consumers to 0.
`bitcoin-stack` is in `bitcoin`. `prometheus` and `tailscale-proxy` are in
`default`.

```bash
nomad job scale -namespace=bitcoin bitcoin-stack bitcoin 0
nomad job scale -namespace=bitcoin bitcoin-stack electrs 0
nomad job scale -namespace=bitcoin bitcoin-stack mempool 0
nomad job scale -namespace=bitcoin bitcoin-stack albyhub 0
nomad job scale -namespace=default prometheus prometheus 0
nomad job scale -namespace=default prometheus grafana 0
nomad job scale -namespace=default tailscale-proxy proxy 0
```

Scale the same groups back to 1 after the NAS is up. `iscsid`
`replacement_timeout` is 600s. An outage longer than that becomes ext4 I/O
errors. A NAS reboot takes cluster DNS (AdGuard) down with it.

Do not upgrade TrueNAS to 26 until democratic-csi ships WebSocket (JSON-RPC)
support. v1.9.5 is REST-only, and TrueNAS 25.10 REST needs the FULL_ADMIN
`nomad-csi` key.

Dead-client failover for the fenced groups (`bitcoin`, `albyhub`): confirm the
Pi is powered off, then purge that node.

```bash
nomad node purge <node-id>
```

After bitcoind moves, mempool import can take 1-3 hours. Alby's LDK will not
sync until Electrs fee estimates work. Restart the `albyhub` task once
bitcoind reports the mempool loaded.

```bash
nomad alloc restart -namespace=bitcoin -task albyhub <alloc-id>
```
