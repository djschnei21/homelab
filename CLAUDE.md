# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Bitcoin infrastructure homelab using HashiCorp Nomad to orchestrate Bitcoin and related services on a Raspberry Pi cluster.

## Architecture

**Cluster Topology:**
- 4 Raspberry Pi nodes in datacenter "homelab"
- 1 Nomad server (pinode2) with single-node bootstrap
- 3 Nomad clients (pinode1, pinode3, pinode4) running Docker

**Services:**
- Bitcoin Core full node with RPC/P2P and transaction indexing
- Electrs - Electrum protocol server (discovers Bitcoin via Nomad service templates)
- Alby Hub - Lightning wallet manager with PostgreSQL backend

**Storage:**
- NFS-backed CSI volumes hosted on external server (192.168.68.50)
- PostgreSQL database for Alby Hub on same external server

## Repository Structure

- `bootstrap/` - Ansible playbooks and roles for cluster initialization
  - `inventory.yml` - Node definitions
  - `nomad/roles/` - common, nomad_server, nomad_client roles
  - `nomad/playbooks/` - Operational playbooks (patching, maintenance)
- `nomad_jobs/` - Nomad job definitions (HCL)
  - `bitcoin/` - Bitcoin-related service jobs
  - `plugins/` - NFS CSI controller and node plugin jobs
- `nomad_namespaces/` - Namespace definitions (bitcoin-ns)
- `nomad_volumes/` - CSI volume definitions for persistent storage

## Commands

Nomad server runs on pinode2. Set the address:
```bash
export NOMAD_ADDR=http://pinode2.local:4646
```

**Deploy a Nomad job:**
```bash
nomad job run -namespace=bitcoin nomad_jobs/bitcoin/bitcoin.nomad.hcl
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
nomad job plan -namespace=bitcoin nomad_jobs/bitcoin/bitcoin.nomad.hcl
```

**Restart a job (re-pulls image):**
```bash
nomad job restart -namespace=bitcoin bitcoin
```

**Bootstrap cluster (Ansible):**
```bash
cd bootstrap/nomad && ansible-playbook -i ../inventory.yml nomad_cluster.yml
```

## Key Patterns

- Services discover each other via Nomad service templates using `nomadService` lookups
- Secrets stored in Nomad variables and accessed via `nomadVar`
- All services use bridge networking with explicit port mappings
- Volumes use `multi-node-single-writer` access mode for read-only sharing across tasks
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
