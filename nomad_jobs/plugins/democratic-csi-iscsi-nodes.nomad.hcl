job "democratic-csi-iscsi-nodes" {
  datacenters = ["homelab"]
  namespace   = "default"
  type        = "system"

  meta {
    version = "2026-10-01"
  }

  # A bad plugin image should not restart on every client in one step.
  update {
    max_parallel = 1
  }

  group "nodes" {
    task "plugin" {
      driver = "docker"

      env {
        CSI_NODE_ID                        = "${attr.unique.hostname}"
        FILESYSTEM_TYPE_DETECTION_STRATEGY = "blkid"
      }

      config {
        image = "democraticcsi/democratic-csi:v1.9.5"

        args = [
          "--csi-version=1.5.0",
          "--csi-name=org.democratic-csi.iscsi",
          "--driver-config-file=${NOMAD_TASK_DIR}/driver-config-file.yaml",
          "--log-level=info",
          "--csi-mode=node",
          "--server-socket=/csi/csi.sock",
        ]

        # iscsiadm in this image chroots to /host and talks to the host iscsid.
        privileged   = true
        ipc_mode     = "host"
        network_mode = "host"

        mount {
          type     = "bind"
          target   = "/host"
          source   = "/"
          readonly = false
        }
      }

      csi_plugin {
        id        = "org.democratic-csi.iscsi"
        type      = "node"
        mount_dir = "/csi"
      }

      # Node attach uses the volume context. No API key in this file.
      template {
        destination = "local/driver-config-file.yaml"
        change_mode = "restart"
        data        = <<EOH
driver: freenas-api-iscsi
instance_id: homelab-iscsi
zfs:
  datasetParentName: homelab-general/nomad-csi
  detachedSnapshotsDatasetParentName: homelab-general/nomad-csi-snapshots
  zvolEnableReservation: false
iscsi:
  targetPortal: "192.168.68.50:3260"
  targetPortals: []
  namePrefix: csi-
  nameSuffix: "-homelab"
  targetGroups:
    - targetGroupPortalGroup: 1
      targetGroupInitiatorGroup: 1
      targetGroupAuthType: CHAP
      targetGroupAuthGroup: 1
  extentInsecureTpc: true
  extentXenCompat: false
  extentDisablePhysicalBlocksize: true
  extentBlocksize: 4096
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
