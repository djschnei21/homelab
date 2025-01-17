data_dir  = "/opt/nomad/data"
datacenter = "homelab"
client {
  enabled = true
  servers = {{ groups['nomad_servers'] | map('extract', hostvars, ['ansible_host']) | list | to_json }}
}