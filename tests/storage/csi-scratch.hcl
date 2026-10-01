# Phase 4 proof volume. 1GiB is the scratch size, not a preflight measurement.
type         = "csi"
id           = "csi-scratch"
name         = "csi-scratch"
plugin_id    = "org.democratic-csi.iscsi"
namespace    = "default"
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
