job "albyhub" {
  datacenters = ["homelab"]
  namespace = "bitcoin"

  group "albyhub-group" {
    reschedule {
      attempts       = 15
      interval       = "1h"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "120s"
      unlimited      = false
    }
    
    volume "albyhub-data" {
      type      = "csi"
      read_only = false
      attachment_mode = "file-system"
      access_mode = "single-node-writer"
      source    = "albyhub-data"
    }

    network {
      mode = "bridge"
      port "http" {
        to = 8080
      }
    }

    task "albyhub" {
      driver = "docker"

      template {
        destination = "${NOMAD_SECRETS_DIR}/env.txt"
        env         = true
        data        = <<EOT
        AUTO_UNLOCK_PASSWORD={{ with nomadVar "nomad/jobs/albyhub" }}{{ .AUTO_UNLOCK_PASSWORD }}{{ end }}
        DATABASE_URI=postgresql://albyhub:{{ with nomadVar "nomad/jobs/albyhub" }}{{ .DB_PASSWORD }}{{ end }}@192.168.68.50:5432/nwc?sslmode=disable
        EOT
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
        image = "ghcr.io/getalby/hub:v1.21.0"
        ports = ["http"]
      }

      resources {
        cpu    = 500     # CPU in MHz
        memory = 1024    # Memory in MB
      }
    }
    
    service {
      name = "albyhub"
      port = "http"
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
