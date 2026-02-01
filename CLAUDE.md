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
- Esplora - Block explorer
- Alby Hub - Lightning wallet manager with PostgreSQL backend

**Storage:**
- NFS-backed CSI volumes hosted on external server (192.168.68.50)
- PostgreSQL database for Alby Hub on same external server

## Repository Structure

- `bootstrap/` - Ansible playbooks and roles for cluster initialization
  - `inventory.yml` - Node definitions
  - `nomad/roles/` - common, nomad_server, nomad_client roles
- `nomad_jobs/` - Nomad job definitions (HCL)
  - `bitcoin/` - Bitcoin-related service jobs
  - `plugins/` - NFS CSI controller and node plugin jobs
- `nomad_namespaces/` - Namespace definitions (bitcoin-ns)
- `nomad_volumes/` - CSI volume definitions for persistent storage

## Commands

**Deploy a Nomad job:**
```bash
nomad job run nomad_jobs/bitcoin/bitcoin.nomad.hcl
```

**Check job status:**
```bash
nomad job status <job-name>
```

**View job logs:**
```bash
nomad alloc logs <alloc-id>
```

**Plan changes before deploy:**
```bash
nomad job plan nomad_jobs/bitcoin/bitcoin.nomad.hcl
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
