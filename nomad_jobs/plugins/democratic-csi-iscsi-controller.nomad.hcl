job "democratic-csi-iscsi-controller" {
  datacenters = ["homelab"]
  namespace   = "default"
  type        = "service"

  meta {
    version = "2026-10-01"
  }

  group "controller" {
    count = 1

    task "plugin" {
      driver = "docker"

      config {
        image = "democraticcsi/democratic-csi:v1.9.5"

        args = [
          "--csi-version=1.5.0",
          "--csi-name=org.democratic-csi.iscsi",
          "--driver-config-file=${NOMAD_SECRETS_DIR}/driver-config-file.yaml",
          "--log-level=info",
          "--csi-mode=controller",
          "--server-socket=/csi/csi.sock",
        ]

        # Same image as the node task. Privileged is required by the driver.
        privileged = true
      }

      csi_plugin {
        id        = "org.democratic-csi.iscsi"
        type      = "controller"
        mount_dir = "/csi"
      }

      # Task path only. A job or group path would be readable by every task.
      template {
        destination = "secrets/driver-config-file.yaml"
        change_mode = "restart"
        data        = <<EOH
driver: freenas-api-iscsi
instance_id: homelab-iscsi
httpConnection:
  protocol: http
  host: 192.168.68.50
  port: 80
  apiKey: "{{ with nomadVar "nomad/jobs/democratic-csi-iscsi-controller/controller/plugin" }}{{ .apiKey }}{{ end }}"
  allowInsecure: true
zfs:
  datasetParentName: homelab-general/csi-scratch
  detachedSnapshotsDatasetParentName: homelab-general/csi-scratch-snapshots
  zvolEnableReservation: false
iscsi:
  targetPortal: "192.168.68.50:3260"
  targetPortals: []
  namePrefix: csi-
  nameSuffix: "-homelab"
  targetGroups:
    - targetGroupPortalGroup: 1
      targetGroupInitiatorGroup: 1
      targetGroupAuthType: None
  extentInsecureTpc: true
  extentXenCompat: false
  extentDisablePhysicalBlocksize: true
  extentBlocksize: 512
  extentRpm: "SSD"
  extentAvailThreshold: 0
EOH
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
