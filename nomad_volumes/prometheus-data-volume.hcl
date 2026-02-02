type = "csi"
id = "prometheus-data"
name = "prometheus-data"
plugin_id = "nfs"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.68.50"
  share = "/mnt/homelab-general/prometheus-data"
}

mount_options {
  fs_type = "nfs"
}
