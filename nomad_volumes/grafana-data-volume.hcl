type = "csi"
id = "grafana-data"
name = "grafana-data"
plugin_id = "nfs"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.68.50"
  share = "/mnt/homelab-general/grafana-data"
}

mount_options {
  fs_type = "nfs"
}
