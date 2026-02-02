job "prometheus" {
  datacenters = ["homelab"]
  namespace   = "default"

  meta {
    version = "2026-02-01-v10"
  }

  group "prometheus" {
    volume "prometheus-data" {
      type            = "csi"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
      source          = "prometheus-data"
    }

    network {
      mode = "bridge"
      port "http" {
        to     = 9090
        static = 9090
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image = "prom/prometheus:v2.48.0"

        args = [
          "--config.file=/etc/prometheus/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--storage.tsdb.retention.time=15d",
          "--web.enable-lifecycle"
        ]

        ports = ["http"]

        volumes = [
          "local/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
        ]
      }

      volume_mount {
        volume      = "prometheus-data"
        destination = "/prometheus"
        read_only   = false
      }

      template {
        data = <<EOF
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  - job_name: "nomad-server"
    metrics_path: "/v1/metrics"
    params:
      format: ["prometheus"]
    static_configs:
      - targets: ["192.168.68.51:4646"]
        labels:
          node: "pinode2"

  - job_name: "nomad-clients"
    metrics_path: "/v1/metrics"
    params:
      format: ["prometheus"]
    static_configs:
      - targets: ["192.168.68.65:4646"]
        labels:
          node: "pinode1"
      - targets: ["192.168.68.64:4646"]
        labels:
          node: "pinode3"
      - targets: ["192.168.68.52:4646"]
        labels:
          node: "pinode4"

  - job_name: "node-exporter"
    static_configs:
      - targets: ["192.168.68.65:9100"]
        labels:
          node: "pinode1"
      - targets: ["192.168.68.64:9100"]
        labels:
          node: "pinode3"
      - targets: ["192.168.68.52:9100"]
        labels:
          node: "pinode4"
EOF
        destination = "local/prometheus.yml"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }

    service {
      name     = "prometheus"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/-/healthy"
        interval = "10s"
        timeout  = "2s"
      }
    }
  }

  group "grafana" {
    volume "grafana-data" {
      type            = "csi"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
      source          = "grafana-data"
    }

    network {
      mode = "bridge"
      port "http" {
        to     = 3000
        static = 3000
      }
    }

    task "grafana" {
      driver = "docker"

      config {
        image = "grafana/grafana:10.2.0"
        ports = ["http"]

        volumes = [
          "local/provisioning/datasources:/etc/grafana/provisioning/datasources:ro",
          "local/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro"
        ]
      }

      volume_mount {
        volume      = "grafana-data"
        destination = "/var/lib/grafana"
        read_only   = false
      }

      template {
        data = <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://{{ range nomadService "prometheus" }}{{ .Address }}:{{ .Port }}{{ end }}
    isDefault: true
EOF
        destination = "local/provisioning/datasources/prometheus.yml"
      }

      template {
        data = <<EOF
apiVersion: 1
providers:
  - name: 'homelab'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards
EOF
        destination = "local/provisioning/dashboards/provider.yml"
      }

      template {
        data            = file("grafana/dashboards/infrastructure.json")
        destination     = "local/provisioning/dashboards/infrastructure.json"
        left_delimiter  = "[["
        right_delimiter = "]]"
      }

      resources {
        cpu    = 300
        memory = 256
      }
    }

    service {
      name     = "grafana"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/api/health"
        interval = "10s"
        timeout  = "2s"
      }
    }
  }
}
