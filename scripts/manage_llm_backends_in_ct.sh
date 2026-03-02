#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install or update LLM backends (vLLM, Ollama, llama.cpp) and manage systemd services in a Proxmox CT.

Usage:
  sudo ./scripts/manage_llm_backends_in_ct.sh \
    --ctid 120 \
    --action install \
    --backend all

Options:
  --ctid <id>              Proxmox CTID (required)
  --action <install|update>
                           Action to perform (default: install)
  --backend <vllm|ollama|llama-cpp|all>
                           Backend target (default: all)
  --venv-path <path>       Python venv path for vLLM (default: /opt/rocm-pytorch-venv)
  --llama-dir <path>       llama.cpp source dir (default: /opt/llama.cpp)
  --service-user <name>    Service account (default: llm-svc)

Notes:
- vLLM is installed/updated into the specified ROCm PyTorch venv.
- Ollama follows official Linux installer flow.
- llama.cpp is built with HIP support (`-DGGML_HIP=ON`) for ROCm.
- Services run as an unprivileged nologin user.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""
ACTION="install"
BACKEND="all"
VENV_PATH="/opt/rocm-pytorch-venv"
LLAMA_DIR="/opt/llama.cpp"
SERVICE_USER="llm-svc"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --action) ACTION="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --venv-path) VENV_PATH="$2"; shift 2 ;;
    --llama-dir) LLAMA_DIR="$2"; shift 2 ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
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

if [[ "${ACTION}" != "install" && "${ACTION}" != "update" ]]; then
  echo "--action must be install or update" >&2
  exit 1
fi

case "${BACKEND}" in
  vllm|ollama|llama-cpp|all) ;;
  *)
    echo "--backend must be one of: vllm, ollama, llama-cpp, all" >&2
    exit 1
    ;;
esac

require_root

if ! pct status "${CTID}" >/dev/null 2>&1; then
  echo "Container ${CTID} does not exist." >&2
  exit 1
fi

if ! pct status "${CTID}" | grep -q "status: running"; then
  echo "Starting CT ${CTID}..."
  pct start "${CTID}"
fi

echo "Running ${ACTION} for ${BACKEND} in CT ${CTID}..."
pct exec "${CTID}" -- env ACTION="${ACTION}" BACKEND="${BACKEND}" VENV_PATH="${VENV_PATH}" LLAMA_DIR="${LLAMA_DIR}" SERVICE_USER="${SERVICE_USER}" bash -s <<'IN_CT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y \
  ca-certificates \
  curl \
  git \
  build-essential \
  cmake \
  ninja-build \
  pkg-config \
  zstd \
  python3 \
  python3-pip

ensure_service_user() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/$SERVICE_USER" --shell /usr/sbin/nologin "$SERVICE_USER"
  fi

  for group in video render; do
    if getent group "$group" >/dev/null 2>&1; then
      usermod -aG "$group" "$SERVICE_USER"
    fi
  done

  install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "/var/lib/$SERVICE_USER"
  install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "/var/lib/$SERVICE_USER/models"
}

install_or_update_vllm() {
  if [[ ! -x "$VENV_PATH/bin/python" ]]; then
    echo "vLLM requires existing venv at $VENV_PATH. Create it first (create_pytorch_venv_in_ct.sh)." >&2
    exit 1
  fi

  "$VENV_PATH/bin/python" -m pip install --upgrade pip setuptools wheel
  "$VENV_PATH/bin/python" -m pip install --upgrade vllm

  cat >/etc/default/vllm <<'EOF'
VLLM_MODEL=/opt/models/your-model
VLLM_PORT=8000
EOF

  cat >/etc/systemd/system/vllm.service <<EOF
[Unit]
Description=vLLM OpenAI-Compatible API Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
SupplementaryGroups=video render
WorkingDirectory=/var/lib/$SERVICE_USER
EnvironmentFile=-/etc/default/vllm
ExecStart=/bin/bash -lc '$VENV_PATH/bin/python -m vllm.entrypoints.openai.api_server --host 0.0.0.0 --port \${VLLM_PORT:-8000} --model "\${VLLM_MODEL}"'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now vllm
}

install_or_update_ollama() {
  if ! command -v zstd >/dev/null 2>&1; then
    apt update
    apt install -y zstd
  fi

  curl -fsSL https://ollama.com/install.sh | bash

  install -d -m 0755 /etc/systemd/system/ollama.service.d
  cat >/etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
SupplementaryGroups=video render
Environment=HOME=/var/lib/$SERVICE_USER
Environment=OLLAMA_MODELS=/var/lib/$SERVICE_USER/models
WorkingDirectory=/var/lib/$SERVICE_USER
EOF

  chown -R "$SERVICE_USER:$SERVICE_USER" "/var/lib/$SERVICE_USER"
  systemctl daemon-reload
  systemctl enable --now ollama || true
}

install_or_update_llama_cpp() {
  if [[ -d "$LLAMA_DIR/.git" ]]; then
    git -C "$LLAMA_DIR" pull --ff-only
  else
    rm -rf "$LLAMA_DIR"
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  fi

  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON
  cmake --build "$LLAMA_DIR/build" -j"$(nproc)"

  cat >/etc/default/llama-cpp <<'EOF'
LLAMA_MODEL=/opt/models/your-model.gguf
LLAMA_PORT=8080
LLAMA_CTX=4096
EOF

  cat >/etc/systemd/system/llama-cpp.service <<EOF
[Unit]
Description=llama.cpp HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
SupplementaryGroups=video render
WorkingDirectory=/var/lib/$SERVICE_USER
EnvironmentFile=-/etc/default/llama-cpp
ExecStart=/bin/bash -lc '$LLAMA_DIR/build/bin/llama-server -m "\${LLAMA_MODEL}" -c \${LLAMA_CTX:-4096} --host 0.0.0.0 --port \${LLAMA_PORT:-8080}'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now llama-cpp
}

case "$BACKEND" in
  vllm)
    ensure_service_user
    install_or_update_vllm
    ;;
  ollama)
    ensure_service_user
    install_or_update_ollama
    ;;
  llama-cpp)
    ensure_service_user
    install_or_update_llama_cpp
    ;;
  all)
    ensure_service_user
    install_or_update_vllm
    install_or_update_ollama
    install_or_update_llama_cpp
    ;;
esac

systemctl daemon-reload
IN_CT

echo "Done."
echo "Service status commands:"
echo "  pct exec ${CTID} -- systemctl status vllm --no-pager"
echo "  pct exec ${CTID} -- systemctl status ollama --no-pager"
echo "  pct exec ${CTID} -- systemctl status llama-cpp --no-pager"
