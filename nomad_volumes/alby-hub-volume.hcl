type = "csi"
id = "albyhub-data"
name = "albyhub-data"
plugin_id = "nfs"
namespace = "bitcoin"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}

parameters {
  server = "192.168.0.3"
  share = "/mnt/homelab-general/albyhub-data"
}

mount_options {
  fs_type = "nfs"
}