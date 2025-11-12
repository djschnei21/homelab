job "plugin-nfs-controller" {
  datacenters = ["homelab"]

  group "controller" {
    task "plugin" {
    driver = "docker"

    config {
      image = "registry.k8s.io/sig-storage/nfsplugin:v4.12.1"
      args = [
        "--endpoint=unix://csi/csi.sock",
        "--nodeid=${attr.unique.hostname}",
        "--logtostderr",
        "-v=5",
      ]
      privileged = true
    }

    csi_plugin {
      id = "nfs"
      type = "controller"
      mount_dir = "/csi"
    }

    resources {
      cpu = 250
      memory = 128
    }
  }
 }
}