# Token for .github/workflows/patch-infra.yml, patch-ready.yml, and
# bootstrap/nomad/playbooks/patch_cluster.yml. Reconcile applies this file
# from main. Mint the token on the runner host so the secret goes straight
# into the file the workflows read:
#
#   (umask 077; mkdir -p ~/.nomad && nomad acl token create -name ci-patch -type client \
#     -policy ci-patch -t '{{ .SecretID }}' > ~/.nomad/patch.token)
#
# node write is the drain and eligibility changes. The rest is read-only.

# -self resolves the local node ID through /v1/agent/self.
agent {
  policy = "read"
}

# node status, server members, node drain -enable/-disable.
node {
  policy = "write"
}

# The drain monitor and node status list only allocations in namespaces the
# token can read. Without this the monitor reports every allocation stopped
# before the drain has moved any.
namespace "bitcoin" {
  capabilities = ["read-job"]
}

namespace "default" {
  capabilities = ["read-job"]
}
