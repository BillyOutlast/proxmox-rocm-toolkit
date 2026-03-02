#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Create a Python venv and install ROCm 7.2 PyTorch wheels inside a Proxmox CT.

Usage:
  sudo ./scripts/create_pytorch_venv_in_ct.sh --ctid 120 [--venv-path /opt/rocm-pytorch-venv]

Options:
  --ctid <id>          Proxmox CTID (required)
  --venv-path <path>   Virtualenv path inside CT (default: /opt/rocm-pytorch-venv)
  --wheel-dir <path>   Directory for wheel downloads inside CT (default: /opt/rocm-pytorch-wheels)

Notes:
- Follows AMD ROCm PyTorch native Linux wheel workflow for ROCm 7.2.
- Uses Python 3.12 wheels (cp312).
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""
VENV_PATH="/opt/rocm-pytorch-venv"
WHEEL_DIR="/opt/rocm-pytorch-wheels"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --venv-path) VENV_PATH="$2"; shift 2 ;;
    --wheel-dir) WHEEL_DIR="$2"; shift 2 ;;
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

echo "Creating ROCm PyTorch venv in CT ${CTID}..."
pct exec "${CTID}" -- env VENV_PATH="${VENV_PATH}" WHEEL_DIR="${WHEEL_DIR}" bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y python3.12-venv python3-pip wget ca-certificates

mkdir -p "$WHEEL_DIR"
cd "$WHEEL_DIR"

TORCH_WHL="torch-2.9.1+rocm7.2.0.lw.git7e1940d4-cp312-cp312-linux_x86_64.whl"
TORCHVISION_WHL="torchvision-0.24.0+rocm7.2.0.gitb919bd0c-cp312-cp312-linux_x86_64.whl"
TRITON_WHL="triton-3.5.1+rocm7.2.0.gita272dfa8-cp312-cp312-linux_x86_64.whl"
TORCHAUDIO_WHL="torchaudio-2.9.0+rocm7.2.0.gite3c6ee2b-cp312-cp312-linux_x86_64.whl"

wget -O "$TORCH_WHL" "https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/torch-2.9.1%2Brocm7.2.0.lw.git7e1940d4-cp312-cp312-linux_x86_64.whl"
wget -O "$TORCHVISION_WHL" "https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/torchvision-0.24.0%2Brocm7.2.0.gitb919bd0c-cp312-cp312-linux_x86_64.whl"
wget -O "$TRITON_WHL" "https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/triton-3.5.1%2Brocm7.2.0.gita272dfa8-cp312-cp312-linux_x86_64.whl"
wget -O "$TORCHAUDIO_WHL" "https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/torchaudio-2.9.0%2Brocm7.2.0.gite3c6ee2b-cp312-cp312-linux_x86_64.whl"

python3 -m venv "$VENV_PATH"
source "$VENV_PATH/bin/activate"

python -m pip install --upgrade pip
pip uninstall -y torch torchvision triton torchaudio || true
pip install "$TORCH_WHL" "$TORCHVISION_WHL" "$TORCHAUDIO_WHL" "$TRITON_WHL"

python - <<PY
import torch, torchvision, torchaudio
print("torch:", torch.__version__)
print("torchvision:", torchvision.__version__)
print("torchaudio:", torchaudio.__version__)
print("hip:", torch.version.hip)
print("cuda_is_available:", torch.cuda.is_available())
PY
'

echo "Done."
echo "Activate with: pct exec ${CTID} -- bash -lc 'source ${VENV_PATH}/bin/activate && python -c \"import torch; print(torch.__version__)\"'"
