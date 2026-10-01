# Token for iSCSI volume create, the copy job, scale-down, and alloc stop.
# Apply with the bootstrap token. Mint a 24h token per session. Do not write
# that secret into a workflow file.
#
#   nomad acl policy apply -description "Storage admin" storage-admin nomad_acl/policies/storage-admin.hcl
#   nomad acl token create -name storage-admin -type client -ttl=24h \
#     -policy storage-admin -t '{{ .SecretID }}'
#
# Variable write is only the controller API key and the bitcoind and electrs
# items Phase 5 updates. nomad job scale also checks read-job-scaling.

namespace "default" {
  capabilities = [
    "list-jobs",
    "read-job",
    "plan-job",
    "register-job",
    "scale-job",
    "read-job-scaling",
    "alloc-lifecycle",
    "read-logs",
    "csi-write-volume",
    "csi-read-volume",
    "csi-list-volume",
    "csi-mount-volume",
  ]

  variables {
    path "nomad/jobs/democratic-csi-iscsi-controller/controller/plugin" {
      capabilities = ["write", "read", "list", "destroy"]
    }
  }
}

namespace "bitcoin" {
  capabilities = [
    "list-jobs",
    "read-job",
    "plan-job",
    "register-job",
    "scale-job",
    "read-job-scaling",
    "alloc-lifecycle",
    "read-logs",
    "csi-write-volume",
    "csi-read-volume",
    "csi-list-volume",
    "csi-mount-volume",
  ]

  variables {
    path "nomad/jobs/bitcoin-stack/bitcoin/bitcoind" {
      capabilities = ["write", "read", "list", "destroy"]
    }

    path "nomad/jobs/bitcoin-stack/electrs/electrs" {
      capabilities = ["write", "read", "list", "destroy"]
    }
  }
}

plugin {
  policy = "read"
}

node {
  policy = "read"
}
