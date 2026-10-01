type       = "csi"
id         = "bitcoin-chain"
name       = "bitcoin-chain"
plugin_id  = "org.democratic-csi.iscsi"
namespace  = "bitcoin"

# Planned size from preflight. capacity_max matches it; raise both to expand.
capacity_min = "1100GiB"
capacity_max = "1100GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}
