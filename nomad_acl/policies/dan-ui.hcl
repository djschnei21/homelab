# Dan's personal token for the Nomad web UI, mostly watching deployments.
# Mint on homelab-agent with the bootstrap token. The secret goes to a 0600
# file and is never printed. No TTL, so the UI stays signed in. Revoke with
# nomad acl token delete <accessor>.
#
#   nomad acl policy apply -description "Dan Nomad UI" dan-ui nomad_acl/policies/dan-ui.hcl
#   (umask 077; mkdir -p ~/.nomad && nomad acl token create -name dan-ui -type client \
#     -policy dan-ui -t '{{ .SecretID }}' > ~/.nomad/dan-ui.token)
#
# alloc-lifecycle is the Stop and Restart buttons on allocations. No Nomad
# variables, exec, or submit: this token does not read secrets, open a shell,
# or change a job.

namespace "bitcoin" {
  capabilities = [
    "list-jobs",
    "read-job",
    "read-logs",
    "alloc-lifecycle",
  ]
}

namespace "default" {
  capabilities = [
    "list-jobs",
    "read-job",
    "read-logs",
    "alloc-lifecycle",
  ]
}

node {
  policy = "read"
}

agent {
  policy = "read"
}

plugin {
  policy = "read"
}
