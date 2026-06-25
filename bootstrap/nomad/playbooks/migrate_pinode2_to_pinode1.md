# Nomad Server Migration: pinode2 -> pinode1

This runbook migrates the Nomad server role from `pinode2` to `pinode1` using Ansible inventory state transitions and keeps Raft state continuity by running both as servers in Phase A.

## References

- Nomad server configuration (`bootstrap_expect`, `server_join`):
  - https://developer.hashicorp.com/nomad/docs/configuration/server
- Nomad cluster node connection and join behavior:
  - https://developer.hashicorp.com/nomad/docs/deploy/clusters/connect-nodes
- Raft peer inspection:
  - https://developer.hashicorp.com/nomad/commands/operator/raft/list-peers
- Raft stale peer removal guidance:
  - https://developer.hashicorp.com/nomad/commands/operator/raft/remove-peer

## Preconditions

- Nomad CLI available from the host running commands.
- SSH/Ansible connectivity to all `pinode*` hosts.
- `NOMAD_ADDR` points to the active server.

```bash
export NOMAD_ADDR=http://pinode2.local:4646
```

## Phase 0: Snapshot and Baseline

```bash
nomad operator snapshot save pre-pinode1-promotion.snap
nomad server members
nomad operator raft list-peers
nomad node status
```

## Phase A: Temporary Dual Server Control Plane

Use transition inventory where `pinode1` and `pinode2` are both in `nomad_servers`:

`bootstrap/inventories/migration/phase-a-dual-servers.yml`

Apply migration playbook:

```bash
ansible-playbook -i bootstrap/inventories/migration/phase-a-dual-servers.yml \
  bootstrap/nomad/playbooks/migrate_pinode2_to_pinode1.yml
```

Validate:

```bash
nomad server members
nomad operator raft list-peers
nomad node status
```

Expected outcome:
- Two servers alive (`pinode1`, `pinode2`)
- Two raft peers shown

Optional:
- Transfer leadership to `pinode1` before demotion if desired.

## Phase B: Demote pinode2 to Client

Switch to final inventory where only `pinode1` is in `nomad_servers` and `pinode2` is in `nomad_clients`:

`bootstrap/inventories/migration/final-pinode1-server.yml`

Apply migration playbook:

```bash
ansible-playbook -i bootstrap/inventories/migration/final-pinode1-server.yml \
  bootstrap/nomad/playbooks/migrate_pinode2_to_pinode1.yml
```

Set endpoint to final server and validate:

```bash
export NOMAD_ADDR=http://pinode1.local:4646
nomad server members
nomad operator raft list-peers
nomad node status
```

Expected outcome:
- One server alive (`pinode1`)
- One raft peer shown
- `pinode2`, `pinode3`, `pinode4` ready as clients

If stale peer remains:
- Prefer graceful `nomad server force-leave <name>`
- Use `nomad operator raft remove-peer -peer-id=<id>` only for orphaned/stale peer entries

## Post-Migration

```bash
nomad operator snapshot save post-pinode2-demotion.snap
```

Optionally run maintenance playbook in check mode:

```bash
ansible-playbook -i bootstrap/inventories/migration/final-pinode1-server.yml \
  bootstrap/nomad/playbooks/patch_cluster.yml --check
```

## Rollback

Return to dual-server inventory and rerun migration playbook:

```bash
ansible-playbook -i bootstrap/inventories/migration/phase-a-dual-servers.yml \
  bootstrap/nomad/playbooks/migrate_pinode2_to_pinode1.yml
```

If a severe outage occurs, follow Nomad outage recovery with the pre-change snapshot.
