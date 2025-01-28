job "electrs" {
  datacenters = ["homelab"]
  namespace = "bitcoin"

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
      mode = "bridge"
      port "electrs_rpc" {
        to = 50001
        static = 50001  # Electrs RPC port to expose outside the group
      }
    }

    task "wait-for-sync" {
      lifecycle {
        hook = "prestart"
        sidecar = false
      }

      driver = "docker"

      volume_mount {
        volume      = "bitcoin-data"
        destination = "/data/bitcoin"
        read_only   = true
      }

      template {
        data = <<EOF
          {{ range nomadService "bitcoin-rpc" }}
          BITCOIN_HOST="{{ .Address }}"
          BITCOIN_PORT="{{ .Port }}"
          {{ end }}
          EOF
        destination = "local/env.txt"
        env         = true
      }

      config {
        image = "djschnei/knots:latest"
        command = "/bin/sh"
        args = [
          "-c",
          <<-EOH
          while true; do
            PROGRESS=$(/usr/local/bin/bitcoin-cli \
              -datadir=/data/bitcoin \
              -rpcconnect=${BITCOIN_HOST} \
              -rpcport=${BITCOIN_PORT} \
              getblockchaininfo | jq -r '.verificationprogress')
            echo "Bitcoin sync progress: $PROGRESS"
            if [ "$PROGRESS" = "1.0" ]; then
              echo "Bitcoin sync complete!"
              break
            fi
            sleep 60
          done
          EOH
        ]
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