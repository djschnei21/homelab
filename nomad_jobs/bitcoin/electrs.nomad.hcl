job "electrs" {
  datacenters = ["homelab"]

  group "electrs" {

    # Define the shared volume for Bitcoin data
    volume "bitcoin-data" {
      type      = "csi"
      read_only = true
      attachment_mode = "file-system"
      access_mode = "multi-node-single-writer"
      source    = "bitcoin-data"
    }

    # Define the Electrs-specific volume
    volume "electrs-data" {
      type      = "csi"
      read_only = false
      attachment_mode = "file-system"
      access_mode = "multi-node-single-writer"
      source    = "electrs-data"
    }

    network {
      port "electrs_rpc" {
        static = 50001  # Electrs RPC port to expose outside the group
      }
    }

    # Electrs task (starts after wait-for-knots completes)
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
        image = "getumbrel/electrs:v0.10.6"
        args  = [
          "--log-filters", "INFO",
          "--db-dir", "/data/electrs",
          "--daemon-dir", "/data/bitcoin",
          "--daemon-rpc-addr", "${BITCOIN_RPC}",  # Internal communication with Knots
          "--daemon-p2p-addr", "${BITCOIN_P2P}",  # Internal communication with Knots
          "--electrum-rpc-addr", "0.0.0.0:${NOMAD_PORT_electrs_rpc}"  # Electrs RPC exposed
        ]
        ports = ["electrs_rpc"]
      }

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