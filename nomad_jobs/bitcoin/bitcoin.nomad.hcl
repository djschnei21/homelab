job "bitcoin" {
  datacenters = ["homelab"]
  namespace   = "bitcoin"

  meta {
    version = "2026-02-01"
  }

  group "bitcoin" {
    reschedule {
      attempts       = 15
      interval       = "1h"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "120s"
      unlimited      = false
    }

    volume "bitcoin-data" {
      type            = "csi"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
      source          = "bitcoin-data"
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

    task "bitcoin" {
      driver = "docker"

      config {
        image      = "bitcoin/bitcoin:latest"
        force_pull = true

        entrypoint = ["bitcoind"]

        args = [
          "-datadir=/data",
          "-server=1",
          "-txindex=1",
          "-rpcbind=0.0.0.0",
          "-rpcport=8332",
          "-rpcallowip=0.0.0.0/0",
          "-port=8333",
          "-printtoconsole"
        ]

        ports = ["bitcoin_rpc", "bitcoin_p2p"]
      }

      user = "3001:3001"

      env {
        BITCOIN_DATA = "/data"
      }

      volume_mount {
        volume      = "bitcoin-data"
        destination = "/data"
        read_only   = false
      }

      resources {
        memory = 4096
        cpu    = 1500
      }

      service {
        name     = "bitcoin-rpc"
        tags     = ["bitcoin"]
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
        tags     = ["bitcoin"]
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