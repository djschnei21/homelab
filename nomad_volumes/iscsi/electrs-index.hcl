type       = "csi"
id         = "electrs-index"
name       = "electrs-index"
plugin_id  = "org.democratic-csi.iscsi"
namespace  = "bitcoin"

# Planned size from preflight. capacity_max matches it; raise both to expand.
capacity_min = "80GiB"
capacity_max = "80GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}
