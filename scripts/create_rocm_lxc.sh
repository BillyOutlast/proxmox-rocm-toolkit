#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Create an unprivileged Ubuntu 24.04 LXC on Proxmox using community-scripts.

Usage:
  sudo ./scripts/create_rocm_lxc.sh \
    --ctid 120 \
    --hostname rocm-ct \
    --template-storage local \
    --container-storage local-lvm

Optional:
  --rootfs-size 32            (GiB, default: 32; mapped to var_disk)
  --cores 8                   (default: 8)
  --memory 16384              (MiB, default: 16384)
  --swap 2048                 (MiB, default: 2048)
  --bridge vmbr0              (default: vmbr0)
  --ip dhcp                   (default: dhcp)
  --gateway 192.168.1.1       (optional)
  --dns 1.1.1.1               (optional)
  --password 'StrongPass123'  (optional)
  --onboot 1                  (default: 1)
  --script-ref main           (default: main; can be a commit SHA)

Notes:
- Run this on a Proxmox host as root.
- Uses https://raw.githubusercontent.com/community-scripts/ProxmoxVE/<ref>/ct/ubuntu.sh
- The community script creates Ubuntu and runs ubuntu-install.sh internally.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""
HOSTNAME=""
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE=""
ROOTFS_SIZE=32
CORES=8
MEMORY=16384
SWAP=2048
BRIDGE="vmbr0"
IP="dhcp"
GATEWAY=""
DNS=""
PASSWORD=""
ONBOOT=1
SCRIPT_REF="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --template) TEMPLATE_STORAGE="$2"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
    --container-storage|--storage) CONTAINER_STORAGE="$2"; shift 2 ;;
    --rootfs-size) ROOTFS_SIZE="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --swap) SWAP="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --onboot) ONBOOT="$2"; shift 2 ;;
    --script-ref) SCRIPT_REF="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${CTID}" || -z "${HOSTNAME}" || -z "${CONTAINER_STORAGE}" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

require_root

if pct status "${CTID}" >/dev/null 2>&1; then
  echo "Container ${CTID} already exists. Aborting." >&2
  exit 1
fi

SCRIPT_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/${SCRIPT_REF}/ct/ubuntu.sh"

echo "Creating LXC ${CTID} (${HOSTNAME}) using community script ${SCRIPT_URL}..."

export APP="Ubuntu"
export CTID="${CTID}"
export var_hostname="${HOSTNAME}"
export var_os="ubuntu"
export var_version="24.04"
export var_unprivileged="1"
export var_cpu="${CORES}"
export var_ram="${MEMORY}"
export var_disk="${ROOTFS_SIZE}"
export var_brg="${BRIDGE}"
export var_net="${IP}"
export var_template_storage="${TEMPLATE_STORAGE}"
export var_container_storage="${CONTAINER_STORAGE}"
export var_nesting="1"
export var_keyctl="1"
export var_mknod="0"
export var_fuse="no"
export var_tun="no"
export var_apt_cacher="no"
export CT_TIMEZONE="host"

if [[ -n "${GATEWAY}" ]]; then
  export var_gateway="${GATEWAY}"
fi

if [[ -n "${DNS}" ]]; then
  export var_ns="${DNS}"
fi

if [[ -n "${PASSWORD}" ]]; then
  export var_pw="${PASSWORD}"
fi

bash -c "$(curl -fsSL "${SCRIPT_URL}")"

if [[ "${ONBOOT}" == "1" ]]; then
  pct set "${CTID}" --onboot 1 >/dev/null
fi

if [[ "${SWAP}" != "0" ]]; then
  pct set "${CTID}" --swap "${SWAP}" >/dev/null
fi

echo "Starting container ${CTID}..."
pct start "${CTID}"

echo "Done. Next steps:"
echo "1) Configure GPU passthrough: ./scripts/configure_gpu_passthrough.sh --ctid ${CTID}"
echo "2) Install ROCm in CT:       ./scripts/install_rocm_in_ct.sh --ctid ${CTID}"
