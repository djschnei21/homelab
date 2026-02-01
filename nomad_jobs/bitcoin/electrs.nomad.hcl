job "electrs" {
  datacenters = ["homelab"]
  namespace = "bitcoin"

  meta {
    version = "2026-02-01.1"
  }

  group "electrs" {

    volume "bitcoin-data" {
      type      = "csi"
      read_only = true
      attachment_mode = "file-system"
      access_mode = "multi-node-single-writer"
      source    = "bitcoin-data"
    }

    volume "electrs-data" {
      type      = "csi"
      read_only = false
      attachment_mode = "file-system"
      access_mode = "multi-node-single-writer"
      source    = "electrs-data"
    }

    network {
      mode = "bridge"
      port "electrs_rpc" {
        to = 50001
        static = 50001
      }
    }

    task "electrs" {
      driver = "docker"

      template {
        data = <<EOF
{{ range nomadService "bitcoin-rpc" }}
BITCOIN_RPC="{{ .Address }}:{{ .Port }}"
{{ end }}
{{ range nomadService "bitcoin-p2p" }}
BITCOIN_P2P="{{ .Address }}:{{ .Port }}"
{{ end }}
EOF
        destination = "local/env.txt"
        env         = true
      }

      config {
        image = "getumbrel/electrs:v0.10.10"
        args  = [
          "--log-filters", "INFO",
          "--db-dir", "/data/electrs",
          "--daemon-dir", "/data/bitcoin",
          "--daemon-rpc-addr", "${BITCOIN_RPC}",
          "--daemon-p2p-addr", "${BITCOIN_P2P}",
          "--electrum-rpc-addr", "0.0.0.0:${NOMAD_PORT_electrs_rpc}"
        ]
        ports = ["electrs_rpc"]
      }

      user = "3001:3001"

      volume_mount {
        volume      = "electrs-data"
        destination = "/data/electrs"
        read_only   = false
      }

      volume_mount {
        volume      = "bitcoin-data"
        destination = "/data/bitcoin"
        read_only   = true
      }

      resources {
        memory = 2048
      }

      service {
        name     = "electrs-rpc"
        tags     = ["electrum"]
        port     = "electrs_rpc"
        provider = "nomad"
      }
    }
  }
}