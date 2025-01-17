data_dir  = "/opt/nomad/data"
bind_addr = "0.0.0.0"
datacenter = "homelab"
server {
  enabled          = true
  bootstrap_expect = 1
  license_path = "/etc/nomad.d/license.hclic"
}