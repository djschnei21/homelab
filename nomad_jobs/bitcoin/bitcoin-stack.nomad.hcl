job "bitcoin-stack" {
  datacenters = ["homelab"]
  namespace   = "bitcoin"

  meta {
    version = "2026-02-01"
  }

  # Bitcoin Core - base layer, no dependencies
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

    task "bitcoind" {
      driver = "docker"

      config {
        image = "bitcoin/bitcoin:30.2"

        entrypoint = ["bitcoind"]

        args = [
          "-datadir=/data",
          "-server=1",
          "-txindex=1",
          "-rpcbind=0.0.0.0",
          "-rpcport=8332",
          "-rpcallowip=0.0.0.0/0",
          "-rpcauth=mempool:wah8FSNZimOwaVjk$778fbe16ffc1f389e22cf5034c8aacab284226e50974800be4d4c637a57a3a77",
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

  # Electrs - depends on Bitcoin Core
  group "electrs" {
    volume "bitcoin-data" {
      type            = "csi"
      read_only       = true
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
      source          = "bitcoin-data"
    }

    volume "electrs-data" {
      type            = "csi"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
      source          = "electrs-data"
    }

    network {
      mode = "bridge"
      port "electrs_rpc" {
        to     = 50001
        static = 50001
      }
    }

    # Init task - wait for bitcoin-rpc to be available
    task "await-bitcoin" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "busybox:1.36"
        command = "sh"
        args    = ["-c", "echo 'Waiting for bitcoin-rpc...'; until nc -z $BITCOIN_HOST $BITCOIN_PORT; do echo 'bitcoin-rpc not ready, retrying...'; sleep 5; done; echo 'bitcoin-rpc is available'"]
      }

      template {
        data = <<EOF
{{ range nomadService "bitcoin-rpc" }}
BITCOIN_HOST={{ .Address }}
BITCOIN_PORT={{ .Port }}
{{ end }}
EOF
        destination = "local/env"
        env         = true
      }

      resources {
        memory = 32
        cpu    = 50
      }
    }

    task "electrs" {
      driver = "docker"

      template {
        data = <<EOF
{{ range nomadService "bitcoin-rpc" }}
BITCOIN_RPC={{ .Address }}:{{ .Port }}
{{ end }}
{{ range nomadService "bitcoin-p2p" }}
BITCOIN_P2P={{ .Address }}:{{ .Port }}
{{ end }}
EOF
        destination = "local/env.txt"
        env         = true
      }

      config {
        image = "getumbrel/electrs:v0.10.10"
        args = [
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

  # Mempool - depends on Bitcoin Core and Electrs
  group "mempool" {
    reschedule {
      attempts       = 15
      interval       = "1h"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "120s"
      unlimited      = false
    }

    network {
      mode = "bridge"
      port "frontend" {
        to     = 8080
        static = 3006
      }
      port "backend" {
        to = 8999
      }
      port "mariadb" {
        to = 3306
      }
    }

    # Init task - wait for bitcoin-rpc and electrs-rpc to be available
    task "await-services" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "busybox:1.36"
        command = "sh"
        args = ["-c", <<EOF
echo 'Waiting for mariadb...'
until nc -z 127.0.0.1 3306; do
  echo 'mariadb not ready, retrying...'
  sleep 2
done
echo 'mariadb is available'

echo 'Waiting for bitcoin-rpc...'
until nc -z $BITCOIN_HOST $BITCOIN_PORT; do
  echo 'bitcoin-rpc not ready, retrying...'
  sleep 5
done
echo 'bitcoin-rpc is available'

echo 'Waiting for electrs-rpc...'
until nc -z $ELECTRS_HOST $ELECTRS_PORT; do
  echo 'electrs-rpc not ready, retrying...'
  sleep 5
done
echo 'electrs-rpc is available'

echo 'All services ready'
EOF
        ]
      }

      template {
        data = <<EOF
{{ range nomadService "bitcoin-rpc" }}
BITCOIN_HOST={{ .Address }}
BITCOIN_PORT={{ .Port }}
{{ end }}
{{ range nomadService "electrs-rpc" }}
ELECTRS_HOST={{ .Address }}
ELECTRS_PORT={{ .Port }}
{{ end }}
EOF
        destination = "local/env"
        env         = true
      }

      resources {
        memory = 32
        cpu    = 50
      }
    }

    # MariaDB - sidecar (starts first, runs for lifetime)
    task "mariadb" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image = "mariadb:11.4"
        ports = ["mariadb"]
      }

      env {
        MYSQL_DATABASE      = "mempool"
        MYSQL_USER          = "mempool"
        MYSQL_PASSWORD      = "mempool"
        MYSQL_ROOT_PASSWORD = "mempool_root"
      }

      resources {
        memory = 512
        cpu    = 500
      }
    }

    # Backend - connects to Bitcoin Core, Electrs, and MariaDB
    task "backend" {
      driver = "docker"

      template {
        data = <<EOF
{{ range nomadService "bitcoin-rpc" }}
CORE_RPC_HOST={{ .Address }}
CORE_RPC_PORT={{ .Port }}
{{ end }}
{{ range nomadService "electrs-rpc" }}
ELECTRUM_HOST={{ .Address }}
ELECTRUM_PORT={{ .Port }}
{{ end }}
{{ with nomadVar "nomad/jobs/bitcoin" }}
CORE_RPC_USERNAME={{ .rpc_user }}
CORE_RPC_PASSWORD={{ .rpc_password }}
{{ end }}
EOF
        destination = "local/services.env"
        env         = true
      }

      config {
        image = "mempool/backend:latest"
        ports = ["backend"]
      }

      env {
        MEMPOOL_BACKEND      = "electrum"
        MEMPOOL_NETWORK      = "mainnet"
        ELECTRUM_TLS_ENABLED = "false"
        DATABASE_ENABLED     = "true"
        DATABASE_HOST        = "127.0.0.1"
        DATABASE_PORT        = "3306"
        DATABASE_DATABASE    = "mempool"
        DATABASE_USERNAME    = "mempool"
        DATABASE_PASSWORD    = "mempool"
        STATISTICS_ENABLED   = "true"
      }

      resources {
        memory = 2048
        cpu    = 1000
      }

      service {
        name     = "mempool-backend"
        port     = "backend"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "backend"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }

    # Frontend - serves UI, proxies to backend
    task "frontend" {
      driver = "docker"

      config {
        image = "mempool/frontend:latest"
        ports = ["frontend"]
      }

      env {
        BACKEND_MAINNET_HTTP_HOST = "127.0.0.1"
        BACKEND_MAINNET_HTTP_PORT = "8999"
        FRONTEND_HTTP_PORT        = "8080"
      }

      resources {
        memory = 256
        cpu    = 200
      }

      service {
        name     = "mempool-frontend"
        port     = "frontend"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
