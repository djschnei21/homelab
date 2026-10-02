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
      access_mode     = "single-node-writer"
      source          = "tailscale-state"
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

      # Nomad lets any workload identity read services in any namespace, so
      # this token needs no ACL policy for the bitcoin lookups.
      identity {
        env         = true
        change_mode = "restart"
      }

      env {
        NOMAD_API  = "http://192.168.68.65:4646"
        TS_TAILNET = "whale-sidewinder.ts.net"
      }

      template {
        data        = <<EOF
import http.client, json, os, re, ssl, threading, time, urllib.request

API = os.environ.get("NOMAD_API", "http://192.168.68.65:4646")
TOKEN = os.environ.get("NOMAD_TOKEN", "")
TAILNET = os.environ.get("TS_TAILNET", "whale-sidewinder.ts.net")
CADDY = "/alloc/Caddyfile"
ELECTRS = "/alloc/electrs.env"
# electrs-gw's tailscaled HTTP proxy is this group's only way into the tailnet.
WARM_PROXY = ("127.0.0.1", 1055)
WARM_SECONDS = 600
WARM_RETRY = 10

def svc(name, ns="default"):
    url = f"{API}/v1/service/{name}?namespace={ns}"
    req = urllib.request.Request(url, headers={"X-Nomad-Token": TOKEN})
    with urllib.request.urlopen(req, timeout=5) as r:
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

# Caddy fetches a site's cert during the first TLS handshake, which can outlast
# the first real visitor. A verified handshake per site gets it in early.
def warm(name, deadline):
    host = f"{name}.{TAILNET}"
    ctx = ssl.create_default_context()
    err = None
    while (left := deadline - time.monotonic()) > 0:
        conn = http.client.HTTPSConnection(*WARM_PROXY, timeout=min(90, left), context=ctx)
        conn.set_tunnel(host, 443)
        try:
            conn.connect()
            print(f"warmed {name}", flush=True)
            return
        except Exception as e:
            err = e
        finally:
            conn.close()
        time.sleep(WARM_RETRY)
    print(f"warm failed {name}: {err}", flush=True)

def start_warm(caddy):
    deadline = time.monotonic() + WARM_SECONDS
    threads = []
    for name in re.findall(r"bind tailscale/(\S+)", caddy):
        t = threading.Thread(target=warm, args=(name, deadline), daemon=True)
        t.start()
        threads.append(t)
    return threads

def main():
    last = None
    warming = False
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
            if not warming:
                start_warm(caddy)
                warming = True
        except Exception as e:
            print("render error:", e, flush=True)
        time.sleep(10)

if __name__ == "__main__":
    main()
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

      # Task-level path. A job or group path would let render read the key.
      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/tailscale-proxy/proxy/caddy" }}
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

      volume_mount {
        volume      = "tailscale-proxy-state"
        destination = "/data"
        read_only   = false
      }

      # Read by tailscale up as file:, so the key stays out of argv and the task env.
      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/tailscale-proxy/proxy/electrs-gw" }}{{ .TS_AUTHKEY }}{{ end }}
EOF
        destination = "${NOMAD_SECRETS_DIR}/ts_authkey"
        change_mode = "restart"
      }

      template {
        data        = <<EOF
set -e
mkdir -p /data/electrs-ts
# render warms caddy's certs through the HTTP proxy on 1055.
tailscaled --tun=userspace-networking --statedir=/data/electrs-ts --socket=/tmp/tailscaled.sock --outbound-http-proxy-listen=127.0.0.1:1055 --socks5-server=127.0.0.1:1055 &
sleep 2
tailscale --socket=/tmp/tailscaled.sock up --auth-key="file:$NOMAD_SECRETS_DIR/ts_authkey" --hostname=electrs --advertise-tags=tag:homelab --accept-dns=false
i=0
while [ "$i" -lt 60 ]; do
  if tailscale --socket=/tmp/tailscaled.sock ip -4 >/dev/null 2>&1; then
    break
  fi
  sleep 2
  i=$((i + 1))
done
# electrs.env is data. Sourcing it would run whatever the file contains.
electrs_target() {
  _host=""
  _port=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      # Doubled dollar is HCL escaping. The shell sees one dollar.
      ELECTRS_HOST=*) _host="$${line#ELECTRS_HOST=}" ;;
      ELECTRS_PORT=*) _port="$${line#ELECTRS_PORT=}" ;;
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
