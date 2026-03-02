#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Configure /etc/pve/lxc/<CTID>.conf for unprivileged ROCm GPU passthrough.

Usage:
  sudo ./scripts/configure_gpu_passthrough.sh --ctid 120

What it does:
- Allows /dev/kfd and /dev/dri* device classes in cgroup2
- Bind-mounts /dev/kfd and /dev/dri into the container
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

append_if_missing "lxc.cgroup2.devices.allow: c 226:* rwm"
append_if_missing "lxc.cgroup2.devices.allow: c 235:* rwm"
append_if_missing "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file"
append_if_missing "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"

if pct status "${CTID}" | grep -q "status: running"; then
  echo "Restarting CT ${CTID} to apply new LXC config..."
  pct restart "${CTID}"
else
  echo "Starting CT ${CTID}..."
  pct start "${CTID}"
fi

echo "Done. GPU passthrough directives are present in ${CONF_FILE}."
