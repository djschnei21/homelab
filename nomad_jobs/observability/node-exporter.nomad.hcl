job "node-exporter" {
  datacenters = ["homelab"]
  namespace   = "default"
  type        = "system"

  meta {
    version = "2026-02-01"
  }

  group "exporters" {
    network {
      mode = "host"
      port "metrics" {
        static = 9100
      }
    }

    task "node-exporter" {
      driver = "docker"

      config {
        image        = "prom/node-exporter:v1.7.0"
        network_mode = "host"

        args = [
          "--path.procfs=/host/proc",
          "--path.sysfs=/host/sys",
          "--path.rootfs=/host/root",
          "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
        ]

        volumes = [
          "/proc:/host/proc:ro",
          "/sys:/host/sys:ro",
          "/:/host/root:ro"
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    service {
      name     = "node-exporter"
      port     = "metrics"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/metrics"
        interval = "10s"
        timeout  = "2s"
      }
    }
  }
}
