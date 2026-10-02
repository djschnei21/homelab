variable "shutdown_delay_seconds" {
  type        = number
  default     = 10
  description = "How long the SIGTERM trap sleeps before the task exits."
}

variable "fence" {
  type        = bool
  default     = false
  description = "Add the lost_after fence. Off leaves the split-brain case."
}

variable "target_node" {
  type        = string
  default     = ""
  description = "Client name to pin the holder to. Empty places it on any client."
}

job "csi-scratch-holder" {
  datacenters = ["homelab"]
  namespace   = "default"
  type        = "service"

  group "holder" {
    dynamic "disconnect" {
      for_each = var.fence ? [1] : []
      content {
        lost_after = "12h"
        replace    = false
        reconcile  = "keep_original"
      }
    }

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
      attachment_mode = "file-system"
      read_only       = false
    }

    # A new ext4 root is root:root 0755. This finishes before holder starts.
    task "chown" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image      = "instrumentisto/rsync-ssh:alpine3.23-r3"
        entrypoint = ["/bin/sh"]
        args       = ["-c", "chown 65534:65534 /data"]
      }

      volume_mount {
        volume      = "scratch"
        destination = "/data"
        read_only   = false
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "holder" {
      driver = "docker"

      # Longer than the trap so Nomad does not SIGKILL the sleep.
      kill_timeout = format("%ds", var.shutdown_delay_seconds + 15)

      config {
        image      = "instrumentisto/rsync-ssh:alpine3.23-r3"
        entrypoint = ["/bin/sh"]
        args       = ["/local/hold.sh"]
      }

      user = "65534:65534"

      env {
        NODE_NAME      = "${node.unique.name}"
        SHUTDOWN_DELAY = format("%d", var.shutdown_delay_seconds)
      }

      volume_mount {
        volume      = "scratch"
        destination = "/data"
        read_only   = false
      }

      template {
        destination = "local/hold.sh"
        perms       = "755"
        data        = <<HOLDEREOF
#!/bin/sh
set -eu
data=$${DATA_DIR:-/data}
delay=$SHUTDOWN_DELAY
case "$delay" in
  ""|*[!0-9]*) echo "SHUTDOWN_DELAY must be seconds" >&2; exit 1 ;;
esac
# wait is the foreground command, so SIGTERM runs this trap immediately.
# A foreground sleep would finish first, and Nomad would SIGKILL at kill_timeout.
trap 'echo shutdown trap $delay; kill $! 2>/dev/null || true; sleep "$delay"; exit 0' INT TERM
if [ ! -s "$data/marker" ]; then
  printf 'created %s on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NODE_NAME" > "$data/marker"
fi
printf 'seen %s on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NODE_NAME" >> "$data/visits"
cat "$data/marker"
while true; do
  sleep 3600 &
  wait $!
done
HOLDEREOF
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
