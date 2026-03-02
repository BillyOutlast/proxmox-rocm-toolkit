#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Configure /etc/pve/lxc/<CTID>.conf for unprivileged ROCm GPU passthrough.

Usage:
  sudo ./scripts/configure_gpu_passthrough.sh --ctid 120

What it does:
- Configures Proxmox `devX:` mappings for AMD GPU device nodes
- Cleans up legacy passthrough lines from prior runs
- Restarts container if running

Notes:
- Run on Proxmox host as root.
- Host must already have amdgpu loaded and expose /dev/kfd and /dev/dri.
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

if [[ -z "${CTID}" ]]; then
  echo "--ctid is required." >&2
  usage
  exit 1
fi

require_root

if [[ ! -e /dev/kfd ]]; then
  echo "Host device /dev/kfd not found. Ensure AMD driver is loaded on host." >&2
  exit 1
fi

if [[ ! -d /dev/dri ]]; then
  echo "Host directory /dev/dri not found. Ensure AMD DRM devices exist on host." >&2
  exit 1
fi

CONF_FILE="/etc/pve/lxc/${CTID}.conf"
if [[ ! -f "${CONF_FILE}" ]]; then
  echo "Container config not found: ${CONF_FILE}" >&2
  exit 1
fi

append_if_missing() {
  local line="$1"
  if ! grep -Fqx "${line}" "${CONF_FILE}"; then
    echo "${line}" >> "${CONF_FILE}"
  fi
}

BACKUP_FILE="${CONF_FILE}.bak.$(date +%s)"
cp "${CONF_FILE}" "${BACKUP_FILE}"

cleanup_legacy_lines() {
  sed -i \
    -e '/^lxc\.cgroup2\.devices\.allow: c 226:\* rwm$/d' \
    -e '/^lxc\.cgroup2\.devices\.allow: c 235:\* rwm$/d' \
    -e '/^lxc\.mount\.entry: \/dev\/kfd dev\/kfd none bind,optional,create=file$/d' \
    -e '/^lxc\.mount\.entry: \/dev\/dri dev\/dri none bind,optional,create=dir$/d' \
    -e '/^dev[0-9]\+: \/dev\/kfd,.*$/d' \
    -e '/^dev[0-9]\+: \/dev\/dri\/renderD[0-9]\+,.*$/d' \
    -e '/^dev[0-9]\+: \/dev\/dri\/card[0-9]\+,.*$/d' \
    "${CONF_FILE}"
}

cleanup_legacy_lines

DEVICE_LIST=("/dev/kfd")
for dev in /dev/dri/renderD* /dev/dri/card*; do
  [[ -e "$dev" ]] && DEVICE_LIST+=("$dev")
done

DEV_INDEX=0
for dev in "${DEVICE_LIST[@]}"; do
  append_if_missing "dev${DEV_INDEX}: ${dev},gid=44"
  DEV_INDEX=$((DEV_INDEX + 1))
done

start_ct_or_rollback() {
  if pct start "${CTID}"; then
    return 0
  fi

  echo "Startup failed after GPU config changes. Restoring backup: ${BACKUP_FILE}" >&2
  cp "${BACKUP_FILE}" "${CONF_FILE}"
  echo "Trying to start CT ${CTID} with restored config..." >&2
  pct start "${CTID}" || true
  return 1
}

if pct status "${CTID}" | grep -q "status: running"; then
  echo "Stopping CT ${CTID} to apply new LXC config..."
  pct stop "${CTID}"

  for _ in {1..20}; do
    if pct status "${CTID}" | grep -q "status: stopped"; then
      break
    fi
    sleep 1
  done

  if ! pct status "${CTID}" | grep -q "status: stopped"; then
    echo "Container ${CTID} did not stop cleanly. Check 'pct status ${CTID}' and retry." >&2
    exit 1
  fi

  echo "Starting CT ${CTID}..."
  if ! start_ct_or_rollback; then
    echo "Failed to apply GPU passthrough safely. Original config restored." >&2
    exit 1
  fi
else
  echo "Starting CT ${CTID}..."
  if ! start_ct_or_rollback; then
    echo "Failed to apply GPU passthrough safely. Original config restored." >&2
    exit 1
  fi
fi

echo "Done. GPU passthrough directives are present in ${CONF_FILE}."
