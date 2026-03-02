#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Revert Ollama network exposure in a Proxmox CT by removing the OLLAMA_HOST systemd override.

Usage:
  sudo ./scripts/close_ollama_network_in_ct.sh --ctid 120

Options:
  --ctid <id>        Proxmox CTID (required)
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
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

require_root

if ! pct status "$CTID" >/dev/null 2>&1; then
  echo "Container $CTID does not exist." >&2
  exit 1
fi

if ! pct status "$CTID" | grep -q "status: running"; then
  echo "Starting CT $CTID..."
  pct start "$CTID"
fi

echo "Removing Ollama network override in CT $CTID..."

pct exec "$CTID" -- bash -s <<'IN_CT'
set -euo pipefail

rm -f /etc/systemd/system/ollama.service.d/network.conf
if [[ -d /etc/systemd/system/ollama.service.d ]] && [[ -z "$(ls -A /etc/systemd/system/ollama.service.d)" ]]; then
  rmdir /etc/systemd/system/ollama.service.d || true
fi

systemctl daemon-reload
systemctl restart ollama

echo "Current OLLAMA_HOST override (if any):"
systemctl show ollama -p Environment --no-pager || true
IN_CT

echo "Done."
echo "Ollama is now using its service defaults (commonly localhost-only)."
