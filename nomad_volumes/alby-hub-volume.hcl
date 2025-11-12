type = "csi"
id = "albyhub-data"
name = "albyhub-data"
plugin_id = "nfs"
namespace = "bitcoin"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.68.50"
  share = "/mnt/homelab-general/albyhub-data"
}

mount_options {
  fs_type = "nfs"
}