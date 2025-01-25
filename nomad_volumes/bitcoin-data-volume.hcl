type = "csi"
id = "bitcoin-data"
name = "bitcoin-data"
plugin_id = "nfs"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}

capability {
  access_mode = "multi-node-single-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.0.152"
  share = "/mnt/homelab-general/bitcoin-data"
}

mount_options {
  fs_type = "nfs"
} 