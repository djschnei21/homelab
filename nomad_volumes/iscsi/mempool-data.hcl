type       = "csi"
id         = "mempool-data"
name       = "mempool-data"
plugin_id  = "org.democratic-csi.iscsi"
namespace  = "bitcoin"

# MariaDB plus the backend cache. The index can be rebuilt, so this stays small.
capacity_min = "10GiB"
capacity_max = "10GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}
