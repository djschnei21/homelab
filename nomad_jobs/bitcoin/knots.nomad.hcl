job "knots" {
  datacenters = ["homelab"]

  group "knots" {

    # Define the shared volume for Bitcoin data
    volume "bitcoin-data" {
      type      = "csi"
      read_only = false
      attachment_mode = "file-system"
      access_mode = "multi-node-single-writer"
      source    = "bitcoin-data"
    }

    network {
      port "bitcoin_rpc" {
        static = 8332
      }
      port "bitcoin_p2p" {
        static = 8333
      }
    }

    # Knots task (starts immediately and runs for the duration)
    task "knots" {
      driver = "docker"

      config {
        image   = "djschnei/knots:latest"
        command = "/usr/local/bin/bitcoind"
        args    = [
          "-datadir=/data",
          "-server=1",
          "-rpcbind=0.0.0.0",
          "-rpcport=8332",  # Knots RPC port for internal use
          "-rpcallowip=0.0.0.0/0",
          "-port=8333"      # Knots P2P port for internal use
        ]
        ports = ["bitcoin_rpc","bitcoin_p2p"]
      }

      volume_mount {
        volume      = "bitcoin-data"
        destination = "/data"
        read_only   = false
      }

      resources {
        memory = 2048
      }

      service {
        name     = "bitcoin-rpc"
        tags     = ["knots"]
        port     = "bitcoin_rpc"
        provider = "nomad"
      }

      service {
        name     = "bitcoin-p2p"
        tags     = ["knots"]
        port     = "bitcoin_p2p"
        provider = "nomad"
      }
    }
  }
}