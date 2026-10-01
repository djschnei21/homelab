variable "target_node" {
  type        = string
  default     = ""
  description = "Client to pin csi-scratch to (pinode2, pinode3, or pinode4). Empty places it on any client."
}

job "csi-scratch" {
  datacenters = ["homelab"]
  namespace   = "default"
  type        = "service"

  meta {
    version = "2026-10-01"
  }

  group "sleeper" {
    count = 1

    dynamic "constraint" {
      for_each = var.target_node == "" ? [] : [var.target_node]
      content {
        attribute = "${node.unique.name}"
        value     = constraint.value
      }
    }

    volume "scratch" {
      type            = "csi"
      source          = "csi-scratch"
      access_mode     = "single-node-writer"
      attachment_mode = "block-device"
      read_only       = false
    }

    task "sleeper" {
      driver = "docker"

      # Reuse the plugin image: it already has mkfs.ext4 and blkid, and it is pinned.
      config {
        image      = "democraticcsi/democratic-csi:v1.9.5"
        entrypoint = ["/bin/sh"]
        args       = ["/local/start.sh"]
        privileged = true
      }

      env {
        NODE_NAME = "${node.unique.name}"
      }

      volume_mount {
        volume      = "scratch"
        destination = "/dev/csi-scratch"
        read_only   = false
      }

      template {
        destination = "local/start.sh"
        perms       = "755"
        data        = <<EOH
#!/bin/sh
set -eu
dev=/dev/csi-scratch
mnt=/mnt/csi-scratch
# Block publish does not format. mkfs only when the zvol has no filesystem,
# so a later placement on another client keeps the marker.
if ! /usr/sbin/blkid "$dev" >/dev/null 2>&1; then
  /usr/sbin/mkfs.ext4 -m 0 -F "$dev"
fi
mkdir -p "$mnt"
if ! /usr/bin/mountpoint -q "$mnt"; then
  /usr/bin/mount -o noatime "$dev" "$mnt"
fi
if [ ! -s "$mnt/marker" ]; then
  printf 'created %s on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$${NODE_NAME:-unknown}" > "$mnt/marker"
fi
printf 'seen %s on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$${NODE_NAME:-unknown}" >> "$mnt/visits"
sync
cat "$mnt/marker"
trap 'umount "$mnt" || true; exit 0' INT TERM
while true; do
  sleep 3600
done
EOH
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
