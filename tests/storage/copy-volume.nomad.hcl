variable "namespace" {
  type = string
}

variable "source_volume" {
  type = string
}

variable "dest_volume" {
  type = string
}

variable "chown" {
  type        = string
  description = "uid:gid passed to rsync --chown. Digits only."
}

variable "task_user" {
  type        = string
  default     = ""
  description = "uid:gid the rsync task runs as. Empty keeps the image user."

  validation {
    condition     = var.task_user == "" || regex_replace(var.task_user, "^[0-9]+:[0-9]+$", "") == ""
    error_message = "task_user must be empty or uid:gid digits."
  }
}

variable "dest_subdir" {
  type        = string
  default     = ""
  description = "Relative directory inside the destination mount. Empty copies to the mount root."
}

variable "verify" {
  type        = bool
  default     = false
  description = "Dry-run with --itemize-changes. Non-zero if rsync lists any change."
}

variable "checksum" {
  type        = bool
  default     = false
  description = "Add --checksum to the verify dry-run."
}

# Chain, electrs, and tailscale register this mode. Prometheus, Grafana, and Alby are single-node-writer only.
variable "source_access_mode" {
  type        = string
  default     = "multi-node-single-writer"
  description = "Read-only source claim. The default can run beside a live writer."
}

variable "extra_excludes" {
  type        = list(string)
  default     = []
  description = "Extra rsync --exclude patterns. The chain copy passes /bitcoin-data."
}

job "copy-volume" {
  datacenters = ["homelab"]
  namespace   = var.namespace
  type        = "batch"

  group "copy" {
    restart {
      attempts = 0
      mode     = "fail"
    }

    volume "source" {
      type            = "csi"
      source          = var.source_volume
      access_mode     = var.source_access_mode
      attachment_mode = "file-system"
      read_only       = true
    }

    volume "dest" {
      type            = "csi"
      source          = var.dest_volume
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = false
    }

    # A fresh ext4 root is root:root 0755. Chown it before a non-root rsync starts.
    dynamic "task" {
      for_each = compact([var.task_user])
      labels   = ["chown"]

      content {
        driver = "docker"

        lifecycle {
          hook    = "prestart"
          sidecar = false
        }

        config {
          image      = "instrumentisto/rsync-ssh:alpine3.23-r3"
          entrypoint = ["/bin/sh"]
          args       = ["-c", "chown ${var.task_user} /dest"]
        }

        volume_mount {
          volume      = "dest"
          destination = "/dest"
          read_only   = false
        }

        resources {
          cpu    = 50
          memory = 32
        }
      }
    }

    task "rsync" {
      driver = "docker"

      config {
        image      = "instrumentisto/rsync-ssh:alpine3.23-r3"
        entrypoint = ["/bin/sh"]
        args       = ["/local/copy.sh"]
      }

      # Docker treats an empty user as the image default, so this stays unset unless task_user is uid:gid.
      user = var.task_user

      env {
        CHOWN       = var.chown
        DEST_SUBDIR = var.dest_subdir
        VERIFY         = format("%t", var.verify)
        CHECKSUM       = format("%t", var.checksum)
        EXTRA_EXCLUDES      = join(",", var.extra_excludes)
        EXTRA_EXCLUDE_COUNT = length(var.extra_excludes)
      }

      volume_mount {
        volume      = "source"
        destination = "/src"
        read_only   = true
      }

      volume_mount {
        volume      = "dest"
        destination = "/dest"
        read_only   = false
      }

      template {
        destination = "local/copy.sh"
        perms       = "755"
        data        = <<COPYEOF
#!/bin/sh
set -eu
src=$${SRC_DIR:-/src}
dest_root=$${DEST_DIR:-/dest}

case "$CHOWN" in
  [0-9]*:[0-9]*) ;;
  *) echo "chown must be uid:gid" >&2; exit 1 ;;
esac
user=$${CHOWN%%:*}
group=$${CHOWN#*:}
case "$user" in
  *[!0-9]*) echo "chown must be uid:gid" >&2; exit 1 ;;
esac
case "$group" in
  *[!0-9]*) echo "chown must be uid:gid" >&2; exit 1 ;;
esac

dest=$dest_root
if [ -n "$DEST_SUBDIR" ]; then
  case "$DEST_SUBDIR" in
    /*|*/|*..*|*[!A-Za-z0-9._/-]*)
      echo "dest subdir must be a relative path" >&2
      exit 1
      ;;
  esac
  dest=$dest_root/$DEST_SUBDIR
  if [ "$VERIFY" != true ]; then
    mkdir -p "$dest"
  fi
fi

excludes=$${EXTRA_EXCLUDES:-}
exclude_count=$${EXTRA_EXCLUDE_COUNT:-0}
if [ "$(id -u)" -eq 0 ]; then
  set -- rsync -aH --numeric-ids --delete --exclude=/lost+found --chown="$CHOWN"
else
  # A non-root rsync cannot chown. The process owner is the intended owner.
  set -- rsync -aH --numeric-ids --delete --exclude=/lost+found
fi
if [ -n "$excludes" ] || [ "$exclude_count" != 0 ]; then
  n=0
  set -f
  old_ifs=$IFS
  IFS=,
  for pat in $excludes; do
    n=$((n + 1))
    case "$pat" in
      ""|*,*) echo "exclude must not contain a comma" >&2; IFS=$old_ifs; set +f; exit 1 ;;
      -*) echo "exclude must not start with a dash" >&2; IFS=$old_ifs; set +f; exit 1 ;;
    esac
    set -- "$@" --exclude="$pat"
  done
  IFS=$old_ifs
  set +f
  # A comma inside a pattern splits into more fields than the list had.
  if [ "$n" != "$exclude_count" ]; then
    echo "exclude must not contain a comma" >&2
    exit 1
  fi
fi
set -- "$@" "$src/" "$dest/"
if [ "$VERIFY" = true ]; then
  set -- "$@" --dry-run --itemize-changes
  if [ "$CHECKSUM" = true ]; then
    set -- "$@" --checksum
  fi
  out=$("$@")
  printf '%s' "$out"
  if [ -n "$out" ]; then
    printf '\n'
    exit 1
  fi
  exit 0
fi
exec "$@"
COPYEOF
      }

      resources {
        cpu    = 300
        memory = 256
      }
    }
  }
}
