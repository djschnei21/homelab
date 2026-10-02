type       = "csi"
id         = "grafana-db"
name       = "grafana-db"
plugin_id  = "org.democratic-csi.iscsi"
namespace  = "default"

# Planned size from preflight. capacity_max matches it; raise both to expand.
capacity_min = "1GiB"
capacity_max = "1GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}
