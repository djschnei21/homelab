job "bitcoin-stack" {
  datacenters = ["homelab"]
  namespace   = "bitcoin"

  meta {
    version = "2026-08-20-v4"
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

      # nomadVar renders in templates only, and bitcoind accepts rpcauth as a flag.
      template {
        destination = "${NOMAD_SECRETS_DIR}/rpc.env"
        env         = true
        data        = <<EOT
rpcauth={{ with nomadVar "nomad/jobs/bitcoin-stack/bitcoind" }}{{ .rpcauth }}{{ end }}
EOT
      }

      config {
        image = "bitcoin/bitcoin:31.1"

        entrypoint = ["sh", "-c"]
        args = [<<EOS
if [ -z "$rpcauth" ]; then
  echo "bitcoind rpcauth is not set" >&2
  exit 1
fi
exec bitcoind \
  -datadir=/data \
  -server=1 \
  -txindex=1 \
  -rpcbind=0.0.0.0 \
  -rpcport=8332 \
  -rpcallowip=0.0.0.0/0 \
  -rpcauth="$rpcauth" \
  -port=8333 \
  -printtoconsole
EOS
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
        image   = "busybox:1.38.0"
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
        image = "getumbrel/electrs:v0.11.1"
        args = [
          "--skip-default-conf-files",
          "--log-filters", "INFO",
          "--db-dir", "/opt/electrs",
          "--daemon-dir", "/opt/bitcoin",
          "--cookie-file", "/opt/bitcoin/.cookie",
          "--daemon-rpc-addr", "${BITCOIN_RPC}",
          "--daemon-p2p-addr", "${BITCOIN_P2P}",
          "--electrum-rpc-addr", "0.0.0.0:${NOMAD_PORT_electrs_rpc}"
        ]
        ports = ["electrs_rpc"]
      }

      user = "3001:3001"

      volume_mount {
        volume      = "electrs-data"
        destination = "/opt/electrs"
        read_only   = false
      }

      volume_mount {
        volume      = "bitcoin-data"
        destination = "/opt/bitcoin"
        read_only   = true
      }

      resources {
        memory = 2048
        cpu    = 1000
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
        image   = "busybox:1.38.0"
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
        image = "mariadb:10.5.29"
        ports = ["mariadb"]
      }

      template {
        destination = "${NOMAD_SECRETS_DIR}/env.txt"
        env         = true
        data        = <<EOT
MYSQL_PASSWORD={{ with nomadVar "nomad/jobs/bitcoin-stack/mariadb" }}{{ .MYSQL_PASSWORD }}{{ end }}
MYSQL_ROOT_PASSWORD={{ with nomadVar "nomad/jobs/bitcoin-stack/mariadb" }}{{ .MYSQL_ROOT_PASSWORD }}{{ end }}
EOT
      }

      env {
        MYSQL_DATABASE = "mempool"
        MYSQL_USER     = "mempool"
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
{{ with nomadVar "nomad/jobs/bitcoin-stack/backend" }}
CORE_RPC_USERNAME={{ .rpc_user }}
CORE_RPC_PASSWORD={{ .rpc_password }}
{{ end }}
EOF
        destination = "local/services.env"
        env         = true
      }

      # This path already stores DATABASE_PASSWORD next to rpc_user and rpc_password.
      template {
        destination = "${NOMAD_SECRETS_DIR}/db.env"
        env         = true
        data        = <<EOT
DATABASE_PASSWORD={{ with nomadVar "nomad/jobs/bitcoin-stack/backend" }}{{ .DATABASE_PASSWORD }}{{ end }}
EOT
      }

      config {
        image = "mempool/backend:v3.3.1"
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
        image = "mempool/frontend:v3.3.1"
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

  # Alby Hub - Lightning wallet, depends on Electrs
  group "albyhub" {
    reschedule {
      attempts       = 15
      interval       = "1h"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "120s"
      unlimited      = false
    }

    volume "albyhub-data" {
      type            = "csi"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
      source          = "albyhub-data"
    }

    network {
      mode = "bridge"
      port "http" {
        to = 8080
      }
    }

    # Init task - wait for electrs-rpc to be available
    task "await-electrs" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "busybox:1.38.0"
        command = "sh"
        args    = ["-c", "echo 'Waiting for electrs-rpc...'; until nc -z $ELECTRS_HOST $ELECTRS_PORT; do echo 'electrs-rpc not ready, retrying...'; sleep 5; done; echo 'electrs-rpc is available'"]
      }

      template {
        data = <<EOF
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

    task "albyhub" {
      driver = "docker"

      template {
        destination = "${NOMAD_SECRETS_DIR}/env.txt"
        env         = true
        data        = <<EOT
AUTO_UNLOCK_PASSWORD={{ with nomadVar "nomad/jobs/bitcoin-stack/albyhub" }}{{ .AUTO_UNLOCK_PASSWORD }}{{ end }}
DATABASE_URI=postgresql://albyhub:{{ with nomadVar "nomad/jobs/bitcoin-stack/albyhub" }}{{ .DB_PASSWORD }}{{ end }}@192.168.68.50:5432/nwc?sslmode=disable
EOT
      }

      template {
        data = <<EOF
{{ range nomadService "electrs-rpc" }}
LDK_ELECTRUM_SERVER={{ .Address }}:{{ .Port }}
{{ end }}
EOF
        destination = "local/electrs.env"
        env         = true
      }

      volume_mount {
        volume      = "albyhub-data"
        destination = "/data"
        read_only   = false
      }

      env {
        WORK_DIR = "/data"
      }

      config {
        image = "ghcr.io/getalby/hub:v1.24.0"
        ports = ["http"]
      }

      resources {
        cpu    = 500
        memory = 1024
      }
    }

    service {
      name     = "albyhub"
      port     = "http"
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
