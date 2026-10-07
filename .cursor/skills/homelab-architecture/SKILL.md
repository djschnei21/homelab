---
name: homelab-architecture
description: Map of this homelab and where to look in the repo. Use when someone needs the cluster layout, which service lives where, or which file to open.
---

# Homelab architecture

A map of the cluster and this repo. Procedures, resource sizes, and maintenance commands are in `AGENTS.md` at the repo root. Read that file for them.

## Topology

Datacenter `homelab`. pinode1 is the Nomad server. pinode2, pinode3, and pinode4 are Nomad clients running Docker.

- Inventory: `bootstrap/inventory.yml` (`nomad_servers`, `nomad_clients`)
- Playbook: `bootstrap/nomad/nomad_cluster.yml`
- Roles: `bootstrap/nomad/roles/common`, `nomad_server`, `nomad_client`

## Jobs

| Job | Namespace | File | What it runs |
| --- | --- | --- | --- |
| `bitcoin-stack` | `bitcoin` | `nomad_jobs/bitcoin/bitcoin-stack.nomad.hcl` | `bitcoin`/`bitcoind`, `electrs`, `mempool` (`mariadb`, `backend`, `frontend`), `albyhub` |
| `prometheus` | `default` | `nomad_jobs/observability/prometheus.nomad.hcl` | groups `prometheus` and `grafana` |
| `node-exporter` | `default` | `nomad_jobs/observability/node-exporter.nomad.hcl` | system job, group `exporters`, one task per client |
| `democratic-csi-iscsi-controller` | `default` | `nomad_jobs/plugins/democratic-csi-iscsi-controller.nomad.hcl` | CSI controller |
| `democratic-csi-iscsi-nodes` | `default` | `nomad_jobs/plugins/democratic-csi-iscsi-nodes.nomad.hcl` | CSI node plugin |
| `tailscale-proxy` | `default` | `nomad_jobs/tailscale/tailscale-proxy.nomad.hcl` | group `proxy` |

Namespace `bitcoin` is `nomad_namespaces/bitcoin-ns.nomad.hcl`. `scripts/reconcile-nomad.sh` reads the namespace from the job file, else from the directory (`nomad_jobs/bitcoin` → `bitcoin`; observability, plugins, and tailscale → `default`).

Nomad service names: `bitcoin-rpc`, `bitcoin-p2p`, `electrs-rpc`, `mempool-backend`, `mempool-frontend`, `albyhub`, `prometheus`, `grafana`, `node-exporter`, `tailscale-proxy`.

## Discovery and secrets

Tasks find each other with `nomadService` inside a template (`{{ range nomadService "bitcoin-rpc" }}`, and the same for `electrs-rpc` and the other names above). The lookups are in `nomad_jobs/bitcoin/bitcoin-stack.nomad.hcl` and `nomad_jobs/observability/prometheus.nomad.hcl`.

Secrets are Nomad variables, read in those templates with `nomadVar "nomad/jobs/<job>/<group>/<task>"`. A workload identity reads its own job, group, and task paths. Open the task that consumes the value; that path is the variable.

## Storage

iSCSI zvols on TrueNAS nas2 (`192.168.68.50`), plugin id `org.democratic-csi.iscsi`. Specs are `nomad_volumes/iscsi/*.hcl`. A job's volume `source` is the spec id.

- `bitcoin`: `bitcoin-chain`, `electrs-index`, `mempool-data`, `albyhub-work`
- `default`: `prometheus-tsdb`, `grafana-db`, `tailscale-state`

Create with `scripts/nomad-volume-create.sh`. CHAP is supplied outside git. The specs in the repo have none.

## ACL

Policies live in `nomad_acl/policies/`: `ci-reconcile.hcl`, `ci-patch.hcl`, `storage-admin.hcl`, `dan-ui.hcl`. `.github/workflows/reconcile.yml` applies every `*.hcl` there only when the ref is `refs/heads/main`. Apply from main, not from a PR checkout.

## Deploy

A merge to `main` runs `.github/workflows/reconcile.yml`, which calls `scripts/reconcile-nomad.sh`. The script plans each `nomad_jobs/**/*.nomad.hcl` and submits a real diff. A memory or CPU decrease, or an image downgrade, needs a commit line `Allow-Resource-Decrease: <job>` on the branch. The PR body is not read.

Host patching is `.github/workflows/patch-infra.yml`, `workflow_dispatch` only. The weekly start is the homelab-agent user timer `homelab-patch-dispatch.timer` (Monday 00:00 America/New_York). Units are in `bootstrap/homelab-agent/systemd/user/`. The playbook is `bootstrap/nomad/playbooks/patch_cluster.yml`.

## Leave in AGENTS.md

Tokens, CHAP, rpcauth, drain and scale commands, memory reservations, and NAS reboot handling stay in `AGENTS.md`. This skill names files. It does not repeat those steps or any secret.
