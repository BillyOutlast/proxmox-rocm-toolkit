#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Expose Ollama to the network from inside a Proxmox CT by setting OLLAMA_HOST in a systemd drop-in.

Usage:
  sudo ./scripts/expose_ollama_in_ct.sh --ctid 120 [--listen 0.0.0.0] [--port 11434]

Options:
  --ctid <id>        Proxmox CTID (required)
  --listen <addr>    Listen address (default: 0.0.0.0)
  --port <port>      TCP port (default: 11434)
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""
LISTEN_ADDR="0.0.0.0"
PORT="11434"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --listen) LISTEN_ADDR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$CTID" ]]; then
  echo "--ctid is required." >&2
  usage
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "--port must be a valid TCP port (1-65535)." >&2
  exit 1
fi

require_root

if ! pct status "$CTID" >/dev/null 2>&1; then
  echo "Container $CTID does not exist." >&2
  exit 1
fi

if ! pct status "$CTID" | grep -q "status: running"; then
  echo "Starting CT $CTID..."
  pct start "$CTID"
fi

echo "Configuring Ollama in CT $CTID to listen on ${LISTEN_ADDR}:${PORT}..."

pct exec "$CTID" -- env LISTEN_ADDR="$LISTEN_ADDR" PORT="$PORT" bash -s <<'IN_CT'
set -euo pipefail

install -d /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/network.conf <<EOF
[Service]
Environment=OLLAMA_HOST=${LISTEN_ADDR}:${PORT}
EOF

systemctl daemon-reload
systemctl restart ollama

echo "Ollama bind listeners:"
ss -ltnp | grep ":${PORT}" || true
IN_CT

echo "Done."
echo "From another machine on your network, test with:"
echo "  curl http://<ct-ip>:${PORT}/api/tags"
