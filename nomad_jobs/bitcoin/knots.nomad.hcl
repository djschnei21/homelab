job "knots" {
  datacenters = ["homelab"]
  namespace = "bitcoin"

  group "knots" {
    reschedule {
      attempts       = 15
      interval       = "1h"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "120s"
      unlimited      = false
    }

    # Define the shared volume for Bitcoin data
    volume "bitcoin-data" {
      type      = "csi"
      read_only = false
      attachment_mode = "file-system"
      access_mode = "multi-node-single-writer"
      source    = "bitcoin-data"
    }

    network {
      mode = "bridge" 
      port "bitcoin_rpc" {
        to = 8332
      }
      port "bitcoin_p2p" {
        to = 8333
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
          "-txindex=1",
          "-rpcbind=0.0.0.0",
          "-rpcport=8332",
          "-rpcallowip=0.0.0.0/0",
          "-port=8333"
        ]
        ports = ["bitcoin_rpc","bitcoin_p2p"]
      }

      volume_mount {
        volume      = "bitcoin-data"
        destination = "/data"
        read_only   = false
      }

      resources {
        memory = 4096
        cpu = 1500
      }

      service {
        name     = "bitcoin-rpc"
        tags     = ["knots"]
        port     = "bitcoin_rpc"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "bitcoin_rpc"
          interval = "10s"
          timeout  = "2s"
        }
      }

      service {
        name     = "bitcoin-p2p"
        tags     = ["knots"]
        port     = "bitcoin_p2p"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "bitcoin_p2p"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}