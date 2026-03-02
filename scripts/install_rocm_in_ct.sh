#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install ROCm 7.2 inside Ubuntu 24.04 LXC.

Usage:
  sudo ./scripts/install_rocm_in_ct.sh --ctid 120 [--package rocm]

Options:
  --ctid <id>          Proxmox CTID (required)
  --package <name>     ROCm meta package (default: rocm)
                       Examples: rocm, rocm-hip-runtime, rocm-opencl-runtime

Notes:
- Follows AMD ROCm Ubuntu package-manager method for Ubuntu 24.04 (noble).
- Run from Proxmox host as root.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""
ROCM_PACKAGE="rocm"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --package) ROCM_PACKAGE="$2"; shift 2 ;;
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

if ! pct status "${CTID}" >/dev/null 2>&1; then
  echo "Container ${CTID} does not exist." >&2
  exit 1
fi

if ! pct status "${CTID}" | grep -q "status: running"; then
  echo "Starting CT ${CTID}..."
  pct start "${CTID}"
fi

echo "Installing ROCm package '${ROCM_PACKAGE}' in CT ${CTID}..."
pct exec "${CTID}" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y ca-certificates gnupg wget

mkdir -p /etc/apt/keyrings
wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/rocm.gpg

cat >/etc/apt/sources.list.d/rocm.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2 noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/7.2/ubuntu noble main
EOF

cat >/etc/apt/preferences.d/rocm-pin-600 <<'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

apt install -y ${ROCM_PACKAGE}
"

echo "ROCm install finished. Running quick checks in CT ${CTID}..."
pct exec "${CTID}" -- bash -lc "
set +e
/opt/rocm/bin/rocminfo >/tmp/rocminfo.out 2>&1
ROCINFO_RC=\$?
if [[ -x /opt/rocm/bin/rocm-smi ]]; then
  /opt/rocm/bin/rocm-smi >/tmp/rocm-smi.out 2>&1
fi
set -e

echo \"rocminfo exit code: \${ROCINFO_RC}\"
if [[ \${ROCINFO_RC} -ne 0 ]]; then
  echo \"rocminfo did not succeed. Check /tmp/rocminfo.out in container.\"
fi
"

echo "Done."
