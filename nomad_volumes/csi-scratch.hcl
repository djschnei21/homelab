# Scratch zvol only. Upstream volume-iscsi.hcl uses file-system attachment.
# block-device publishes the raw device so csi-scratch can format it once
# and the same filesystem can move to another client.
type         = "csi"
id           = "csi-scratch"
name         = "csi-scratch"
plugin_id    = "org.democratic-csi.iscsi"
namespace    = "default"
capacity_min = "1GiB"
capacity_max = "1GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "block-device"
}
