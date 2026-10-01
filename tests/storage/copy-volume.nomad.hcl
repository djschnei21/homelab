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

    task "rsync" {
      driver = "docker"

      config {
        image      = "instrumentisto/rsync-ssh:alpine3.23-r3"
        entrypoint = ["/bin/sh"]
        args       = ["/local/copy.sh"]
      }

      env {
        CHOWN       = var.chown
        DEST_SUBDIR = var.dest_subdir
        VERIFY         = format("%t", var.verify)
        CHECKSUM       = format("%t", var.checksum)
        EXTRA_EXCLUDES = join("\n", var.extra_excludes)
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
set -- rsync -aH --numeric-ids --delete --exclude=/lost+found --chown="$CHOWN"
if [ -n "$excludes" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in
      -*) echo "exclude must not be a flag" >&2; exit 1 ;;
    esac
    set -- "$@" --exclude="$pat"
  done <<EXCLUDES
$excludes
EXCLUDES
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
