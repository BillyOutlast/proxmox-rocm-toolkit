#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Create an unprivileged Ubuntu 24.04 LXC on Proxmox.

Usage:
  sudo ./scripts/create_rocm_lxc.sh \
    --ctid 120 \
    --hostname rocm-ct \
    --template local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst \
    --storage local-lvm

Optional:
  --rootfs-size 32            (GiB, default: 32)
  --cores 8                   (default: 8)
  --memory 16384              (MiB, default: 16384)
  --swap 2048                 (MiB, default: 2048)
  --bridge vmbr0              (default: vmbr0)
  --ip dhcp                   (default: dhcp)
  --gateway 192.168.1.1       (optional)
  --dns 1.1.1.1               (optional)
  --password 'StrongPass123'  (optional)
  --onboot 1                  (default: 1)

Notes:
- Run this on a Proxmox host as root.
- This only creates the container. GPU passthrough and ROCm install are separate steps.
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
TEMPLATE=""
STORAGE=""
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
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
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${CTID}" || -z "${HOSTNAME}" || -z "${TEMPLATE}" || -z "${STORAGE}" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

require_root

if pct status "${CTID}" >/dev/null 2>&1; then
  echo "Container ${CTID} already exists. Aborting." >&2
  exit 1
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${IP}"
if [[ -n "${GATEWAY}" ]]; then
  NET0+=",gw=${GATEWAY}"
fi

CREATE_ARGS=(
  "${CTID}"
  "${TEMPLATE}"
  --hostname "${HOSTNAME}"
  --ostype ubuntu
  --rootfs "${STORAGE}:${ROOTFS_SIZE}"
  --cores "${CORES}"
  --memory "${MEMORY}"
  --swap "${SWAP}"
  --unprivileged 1
  --features nesting=1,keyctl=1
  --onboot "${ONBOOT}"
  --net0 "${NET0}"
)

if [[ -n "${DNS}" ]]; then
  CREATE_ARGS+=(--nameserver "${DNS}")
fi

if [[ -n "${PASSWORD}" ]]; then
  CREATE_ARGS+=(--password "${PASSWORD}")
fi

echo "Creating LXC ${CTID} (${HOSTNAME})..."
pct create "${CREATE_ARGS[@]}"

echo "Starting container ${CTID}..."
pct start "${CTID}"

echo "Done. Next steps:"
echo "1) Configure GPU passthrough: ./scripts/configure_gpu_passthrough.sh --ctid ${CTID}"
echo "2) Install ROCm in CT:       ./scripts/install_rocm_in_ct.sh --ctid ${CTID}"
