job "mempool" {
  datacenters = ["homelab"]

  group "db" {
    network {
      port "mysql" {
        to = 3306
      }
    }

    task "db" {
      driver = "docker"
      user   = "1000:1000"

      template {
        data = <<EOH
          MYSQL_DATABASE="mempool"
          MYSQL_USER="mempool"
          MYSQL_PASSWORD="mempool"
          MYSQL_ROOT_PASSWORD="admin"
          EOH
        destination = "secrets/db.env"
        env         = true
      }

      config {
        image = "mariadb:10.5.21"
        ports = ["mysql"]
      }

      service {
        name     = "mempool-db"
        port     = "mysql"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }

  group "backend" {
    volume "bitcoin-data" {
      type            = "csi"
      read_only       = true
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
      source         = "bitcoin-data"
    }

    network {
      port "api" {
        to = 8999
      }
    }

    task "backend" {
      driver = "docker"
      user   = "1000:1000"

      template {
        data = <<EOH
          MEMPOOL_BACKEND="electrum"

          {{ range nomadService "electrs-rpc" }}
          ELECTRUM_HOST="{{ .Address }}"
          ELECTRUM_PORT="{{ .Port }}"
          {{ end }}

          ELECTRUM_TLS_ENABLED="false"

          {{ range nomadService "bitcoin-rpc" }}
          CORE_RPC_HOST="{{ .Address }}"
          CORE_RPC_PORT="{{ .Port }}"
          {{ end }}

          CORE_RPC_COOKIE="true"
          CORE_RPC_COOKIE_PATH="/data/bitcoin/.cookie"
          DATABASE_ENABLED="true"

          {{ range nomadService "mempool-db" }}
          DATABASE_HOST="{{ .Address }}"
          DATABASE_PORT="{{ .Port }}"
          {{ end }}

          DATABASE_DATABASE="mempool"
          DATABASE_USERNAME="mempool"
          DATABASE_PASSWORD="mempool"
          STATISTICS_ENABLED="true"
          EOH
        destination = "local/env.txt"
        env         = true
      }

      volume_mount {
        volume      = "bitcoin-data"
        destination = "/data/bitcoin"
        read_only   = true
      }

      config {
        image = "mempool/backend:latest"
        command = "./wait-for-it.sh ${DATABASE_HOST}:${DATABASE_PORT} --timeout=720 --strict -- ./start.sh"
        ports = ["frontend"]
      }

      service {
        name     = "mempool-backend"
        port     = "api"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }

  group "frontend" {
    network {
      port "http" {
        to = 8080
      }
    }

    task "frontend" {
      driver = "docker"
      user   = "1000:1000"

      template {
        data = <<EOH
          FRONTEND_HTTP_PORT="8080"
          {{ range nomadService "mempool-backend" }}
          BACKEND_MAINNET_HTTP_HOST="{{ .Address }}"
          BACKEND_MAINNET_HTTP_PORT="{{ .Port }}"
          {{ end }}
          {{ range nomadService "mempool-db" }}
          DATABASE_HOST="{{ .Address }}"
          DATABASE_PORT="{{ .Port }}"
          {{ end }}
          EOH
        destination = "local/env.txt"
        env         = true
      }

      config {
        image = "mempool/frontend:latest"
        command = "./wait-for ${DATABASE_HOST}:${DATABASE_PORT} --timeout=720 -- nginx -g 'daemon off;'"
        ports = ["http"]
      }

      service {
        name     = "mempool-frontend"
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
}