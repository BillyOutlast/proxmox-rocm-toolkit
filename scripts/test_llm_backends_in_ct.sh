#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run health checks for vLLM, Ollama, and llama.cpp services inside a Proxmox CT.

Usage:
  sudo ./scripts/test_llm_backends_in_ct.sh --ctid 120 [--backend all] [--verbose]

Options:
  --ctid <id>                Proxmox CTID (required)
  --backend <vllm|ollama|llama-cpp|all>
                             Backend to test (default: all)
  --verbose                  Print service diagnostics on failures
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

CTID=""
BACKEND="all"
VERBOSE="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --verbose) VERBOSE="yes"; shift 1 ;;
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

echo "Testing ${BACKEND} backend(s) in CT ${CTID} (verbose=${VERBOSE})..."

pct exec "${CTID}" -- env BACKEND="${BACKEND}" VERBOSE="${VERBOSE}" bash -s <<'IN_CT'
set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
  apt update
  apt install -y curl
fi

PASS=0
FAIL=0

run_check() {
  local name="$1"
  local cmd="$2"
  local service="${3:-}"
  if eval "$cmd"; then
    echo "[PASS] $name"
    PASS=$((PASS+1))
  else
    echo "[FAIL] $name"
    if [[ "$VERBOSE" == "yes" && -n "$service" ]]; then
      echo "--- ${service}: systemctl status ---"
      systemctl status "$service" --no-pager || true
      echo "--- ${service}: journalctl (last 80 lines) ---"
      journalctl -u "$service" -n 80 --no-pager || true
    fi
    FAIL=$((FAIL+1))
  fi
}

check_vllm() {
  run_check "vLLM systemd active" "systemctl is-active --quiet vllm" "vllm"
  run_check "vLLM HTTP health" "curl -fsS --max-time 5 http://127.0.0.1:8000/health >/dev/null" "vllm"
}

check_ollama() {
  run_check "Ollama systemd active" "systemctl is-active --quiet ollama" "ollama"
  run_check "Ollama version" "ollama --version >/dev/null" "ollama"
  run_check "Ollama tags endpoint" "curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null" "ollama"
}

check_llama_cpp() {
  run_check "llama.cpp systemd active" "systemctl is-active --quiet llama-cpp" "llama-cpp"
  run_check "llama.cpp health" "curl -fsS --max-time 5 http://127.0.0.1:8080/health >/dev/null" "llama-cpp"
}

case "$BACKEND" in
  vllm) check_vllm ;;
  ollama) check_ollama ;;
  llama-cpp) check_llama_cpp ;;
  all)
    check_vllm
    check_ollama
    check_llama_cpp
    ;;
esac

echo "Summary: pass=$PASS fail=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
IN_CT

echo "Done."
