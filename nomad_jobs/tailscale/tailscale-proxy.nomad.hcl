job "tailscale-proxy" {
  datacenters = ["homelab"]
  namespace   = "default"

  meta {
    version = "2026-08-20-v4"
  }

  group "proxy" {
    volume "tailscale-proxy-state" {
      type            = "csi"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
      source          = "tailscale-proxy-state"
    }

    network {
      mode = "bridge"
      port "health" {
        to = 8080
      }
    }

    task "render" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image   = "python:3.12.14-alpine"
        command = "python"
        args    = ["-u", "/local/render.py"]
      }

      env {
        NOMAD_API  = "http://192.168.68.65:4646"
        TS_TAILNET = "whale-sidewinder.ts.net"
      }

      template {
        data        = <<EOF
import json, os, time, urllib.request

API = os.environ.get("NOMAD_API", "http://192.168.68.65:4646")
TAILNET = os.environ.get("TS_TAILNET", "whale-sidewinder.ts.net")
CADDY = "/alloc/Caddyfile"
ELECTRS = "/alloc/electrs.env"

def svc(name, ns="default"):
    url = f"{API}/v1/service/{name}?namespace={ns}"
    with urllib.request.urlopen(url, timeout=5) as r:
        data = json.load(r)
    if not data:
        raise RuntimeError(f"no instances for {name}@{ns}")
    inst = data[0]
    return inst["Address"], inst["Port"]

def site(name, upstream):
    return f'''https://{name}.{TAILNET} {{
  bind tailscale/{name}
  reverse_proxy {upstream}
}}
'''

def render():
    grafana = svc("grafana")
    prometheus = svc("prometheus")
    mempool = svc("mempool-frontend", "bitcoin")
    alby = svc("albyhub", "bitcoin")
    electrs = svc("electrs-rpc", "bitcoin")
    caddy = f'''{{
  auto_https disable_redirects
  servers {{
    protocols h1 h2
  }}
  tailscale {{
    auth_key {{env.TS_AUTHKEY}}
    ephemeral false
    state_dir /data/caddy-ts
    tags tag:homelab

    grafana {{
      hostname grafana
      state_dir /data/caddy-ts/grafana
    }}
    prometheus {{
      hostname prometheus
      state_dir /data/caddy-ts/prometheus
    }}
    mempool {{
      hostname mempool
      state_dir /data/caddy-ts/mempool
    }}
    alby {{
      hostname alby
      state_dir /data/caddy-ts/alby
    }}
  }}
}}

:8080 {{
  respond "ok"
}}

{site("grafana", f"{grafana[0]}:{grafana[1]}")}
{site("prometheus", f"{prometheus[0]}:{prometheus[1]}")}
{site("mempool", f"{mempool[0]}:{mempool[1]}")}
{site("alby", f"{alby[0]}:{alby[1]}")}
'''
    electrs_env = f"ELECTRS_HOST={electrs[0]}\nELECTRS_PORT={electrs[1]}\n"
    return caddy, electrs_env

last = None
while True:
    try:
        caddy, electrs_env = render()
        blob = (caddy, electrs_env)
        if blob != last:
            with open(CADDY, "w") as f:
                f.write(caddy)
            with open(ELECTRS, "w") as f:
                f.write(electrs_env)
            last = blob
            print("wrote upstreams", flush=True)
    except Exception as e:
        print("render error:", e, flush=True)
    time.sleep(10)
EOF
        destination = "local/render.py"
        change_mode = "restart"
        left_delimiter  = "[["
        right_delimiter = "]]"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    task "caddy" {
      driver = "docker"

      config {
        image      = "ghcr.io/tailscale/caddy-tailscale@sha256:d9607d404af12e76df51c5593412bf2a2185126cd2c63b48c6917881166cd3d8"
        entrypoint = ["/bin/sh", "-c"]
        args       = ["while [ ! -s /alloc/Caddyfile ]; do echo waiting for Caddyfile; sleep 2; done; exec caddy run --watch --config /alloc/Caddyfile --adapter caddyfile"]
        ports      = ["health"]
      }

      volume_mount {
        volume      = "tailscale-proxy-state"
        destination = "/data"
        read_only   = false
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/tailscale-proxy" }}
TS_AUTHKEY={{ .TS_AUTHKEY }}
{{ end }}
EOF
        destination = "${NOMAD_SECRETS_DIR}/ts.env"
        env         = true
        change_mode = "restart"
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "tailscale-proxy"
        port     = "health"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }

    task "electrs-gw" {
      driver = "docker"

      config {
        image      = "tailscale/tailscale:v1.102.2"
        entrypoint = ["/bin/sh", "-c"]
        args       = ["exec /bin/sh /local/electrs-gw.sh"]
      }

      env {
        TS_TAILNET = "whale-sidewinder.ts.net"
      }

      volume_mount {
        volume      = "tailscale-proxy-state"
        destination = "/data"
        read_only   = false
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/tailscale-proxy" }}
TS_AUTHKEY={{ .TS_AUTHKEY }}
{{ end }}
EOF
        destination = "${NOMAD_SECRETS_DIR}/ts.env"
        env         = true
        change_mode = "restart"
      }

      template {
        data        = <<EOF
set -e
mkdir -p /data/electrs-ts
tailscaled --tun=userspace-networking --statedir=/data/electrs-ts --socket=/tmp/tailscaled.sock --outbound-http-proxy-listen=127.0.0.1:1055 --socks5-server=127.0.0.1:1055 &
sleep 2
tailscale --socket=/tmp/tailscaled.sock up --auth-key="$TS_AUTHKEY" --hostname=electrs --advertise-tags=tag:homelab --accept-dns=false
i=0
while [ "$i" -lt 60 ]; do
  if tailscale --socket=/tmp/tailscaled.sock ip -4 >/dev/null 2>&1; then
    break
  fi
  sleep 2
  i=$((i + 1))
done
warm() {
  n=0
  while [ "$n" -lt 8 ]; do
    if https_proxy=http://127.0.0.1:1055 wget -q -O /dev/null -T 90 "https://$1.$TS_TAILNET/"; then
      echo "warmed $1"
      return 0
    fi
    n=$((n + 1))
    sleep 5
  done
  echo "warm failed $1"
}
for h in grafana prometheus mempool alby; do
  warm "$h" &
done
# electrs.env is data. Sourcing it would run whatever the file contains.
electrs_target() {
  _host=""
  _port=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      # Doubled dollar is HCL escaping. The shell sees one dollar.
      ELECTRS_HOST=*) _host="$$${line#ELECTRS_HOST=}" ;;
      ELECTRS_PORT=*) _port="$$${line#ELECTRS_PORT=}" ;;
    esac
  done < /alloc/electrs.env
  case "$_host" in
    ""|*[!A-Za-z0-9.-]*) return 1 ;;
  esac
  case "$_host" in
    *[A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$_port" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-5][0-9][0-9][0-9][0-9]|6[0-4][0-9][0-9][0-9]|65[0-4][0-9][0-9]|655[0-2][0-9]|6553[0-5]) ;;
    *) return 1 ;;
  esac
  printf 'tcp://%s:%s\n' "$_host" "$_port"
}
current=""
while true; do
  if [ -s /alloc/electrs.env ]; then
    if dest=$(electrs_target); then
      if [ "$dest" != "$current" ]; then
        tailscale --socket=/tmp/tailscaled.sock serve --tls-terminated-tcp=50002 off || true
        tailscale --socket=/tmp/tailscaled.sock serve --bg --tls-terminated-tcp=50002 "$dest"
        current="$dest"
        echo "serve $dest"
      fi
    else
      echo "electrs upstream rejected"
    fi
  fi
  sleep 10
done
EOF
        destination = "local/electrs-gw.sh"
        change_mode = "restart"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
