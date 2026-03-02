#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Apply a safe Ollama memory profile inside a Proxmox CT (ROCm/LXC friendly).

Usage:
  sudo ./scripts/set_ollama_memory_profile_in_ct.sh --ctid 120

Options:
  --ctid <id>                Proxmox CTID (required)
  --context-length <int>     OLLAMA_CONTEXT_LENGTH (default: 8192)
  --num-parallel <int>       OLLAMA_NUM_PARALLEL (default: 1)
  --max-loaded-models <int>  OLLAMA_MAX_LOADED_MODELS (default: 1)
  --flash-attention <bool>   OLLAMA_FLASH_ATTENTION true|false (default: false)
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""
CONTEXT_LENGTH="8192"
NUM_PARALLEL="1"
MAX_LOADED_MODELS="1"
FLASH_ATTENTION="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --context-length) CONTEXT_LENGTH="$2"; shift 2 ;;
    --num-parallel) NUM_PARALLEL="$2"; shift 2 ;;
    --max-loaded-models) MAX_LOADED_MODELS="$2"; shift 2 ;;
    --flash-attention) FLASH_ATTENTION="$2"; shift 2 ;;
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

if ! [[ "$CONTEXT_LENGTH" =~ ^[0-9]+$ ]] || (( CONTEXT_LENGTH < 256 )); then
  echo "--context-length must be an integer >= 256" >&2
  exit 1
fi

if ! [[ "$NUM_PARALLEL" =~ ^[0-9]+$ ]] || (( NUM_PARALLEL < 1 )); then
  echo "--num-parallel must be an integer >= 1" >&2
  exit 1
fi

if ! [[ "$MAX_LOADED_MODELS" =~ ^[0-9]+$ ]] || (( MAX_LOADED_MODELS < 1 )); then
  echo "--max-loaded-models must be an integer >= 1" >&2
  exit 1
fi

case "$FLASH_ATTENTION" in
  true|false) ;;
  *)
    echo "--flash-attention must be true or false" >&2
    exit 1
    ;;
esac

require_root

if ! pct status "$CTID" >/dev/null 2>&1; then
  echo "Container $CTID does not exist." >&2
  exit 1
fi

if ! pct status "$CTID" | grep -q "status: running"; then
  echo "Starting CT $CTID..."
  pct start "$CTID"
fi

echo "Applying Ollama memory profile in CT $CTID..."

pct exec "$CTID" -- env \
  CONTEXT_LENGTH="$CONTEXT_LENGTH" \
  NUM_PARALLEL="$NUM_PARALLEL" \
  MAX_LOADED_MODELS="$MAX_LOADED_MODELS" \
  FLASH_ATTENTION="$FLASH_ATTENTION" \
  bash -s <<'IN_CT'
set -euo pipefail

install -d /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/20-memory-tuning.conf <<EOF
[Service]
Environment=OLLAMA_CONTEXT_LENGTH=${CONTEXT_LENGTH}
Environment=OLLAMA_MAX_LOADED_MODELS=${MAX_LOADED_MODELS}
Environment=OLLAMA_NUM_PARALLEL=${NUM_PARALLEL}
Environment=OLLAMA_FLASH_ATTENTION=${FLASH_ATTENTION}
EOF

systemctl daemon-reload
systemctl restart ollama

systemctl show ollama -p Environment --no-pager || true
IN_CT

echo "Done."
echo "Recommended validation:"
echo "  pct exec ${CTID} -- journalctl -u ollama -n 120 --no-pager | egrep -i 'inference compute|out of memory|Load failed|KvSize'"
