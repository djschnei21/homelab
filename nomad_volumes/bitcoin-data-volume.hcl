type = "csi"
id = "bitcoin-data"
name = "bitcoin-data"
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

parameters {
  server = "192.168.68.50"
  share = "/mnt/homelab-general/bitcoin-data"
}

mount_options {
  fs_type = "nfs"
}