type = "csi"
id = "electrs-data"
name = "electrs-data"
plugin_id = "nfs"
namespace = "bitcoin"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}

capability {
  access_mode = "multi-node-single-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.0.3"
  share = "/mnt/homelab-general/electrs-data"
}

mount_options {
  fs_type = "nfs"
} 