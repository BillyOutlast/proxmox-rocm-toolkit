# AMD AI Max+ 395 / Radeon 8060S Proxmox Optimization Guide

Target system: AMD AI Max+ 395, Radeon 8060S (iGPU), 128GB LPDDR5X-8000

This guide is tuned for your toolkit workflow (unprivileged Ubuntu 24.04 LXC + ROCm + vLLM/Ollama/llama.cpp).

Companion preset matrix:

- [AMD AI Max+ 395 Profile Presets](AI_MAX_395_PROFILE_PRESETS.md)

## 1) Goals and constraints

- Single-node Proxmox with shared CPU+GPU memory (UMA)
- Maximize stable tokens/sec for local inference
- Avoid host memory starvation and swap thrash
- Keep setup reproducible with scripts in this repo

## 2) BIOS / firmware baseline

Use the latest stable BIOS and apply these principles:

- Set GPU/UMA memory to the highest stable option available.
- Disable memory downclock/power-saving modes that cap bandwidth under load.
- Prefer performance-oriented power profile over quiet/eco profile.
- Keep virtualization enabled (SVM/IOMMU).

If your BIOS exposes only vendor presets, pick the highest-performance preset that is thermally sustainable.

## 3) Proxmox host baseline

### 3.1 Update host and firmware packages

```bash
apt update && apt full-upgrade -y
reboot
```

### 3.2 CPU governor for inference workloads

```bash
apt install -y linux-cpupower
cpupower frequency-set -g performance
```

Persist via systemd if needed.

### 3.3 Keep host memory headroom

For 128GB UMA, reserve host memory for Proxmox + cache + service overhead:

- Reserve at least 24-32GB for host
- Allocate 90-100GB to LXC for LLM workloads

Avoid driving host free memory near zero under sustained load.

### 3.4 Disk and filesystem

- Put model cache + wheels on NVMe
- Keep `noatime` for model/data paths where possible
- If using ZFS for model storage, prefer `compression=zstd` and avoid tiny record sizes

## 4) LXC sizing recommendations

For your hardware, start with:

- `--cores 12` to `--cores 16`
- `--memory 98304` (96GB) or `106496` (104GB)
- `--swap 0` (preferred) or small swap (`4096`) only as safety net
- `--rootfs-size 100+` GB if storing multiple GGUF / HF models in CT

Example:

```bash
sudo bash ./scripts/create_rocm_lxc.sh \
  --ctid 120 \
  --hostname rocm-base \
  --template-storage local \
  --container-storage local-lvm \
  --cores 16 \
  --memory 98304 \
  --swap 0 \
  --rootfs-size 120
```

## 5) GPU passthrough and ROCm stack

Run the toolkit sequence:

```bash
sudo bash ./scripts/configure_gpu_passthrough.sh --ctid 120
sudo bash ./scripts/install_rocm_in_ct.sh --ctid 120 --package rocm
```

Validation:

```bash
pct exec 120 -- bash -lc '/opt/rocm/bin/rocminfo | head -n 60'
pct exec 120 -- bash -lc '/opt/rocm/bin/rocm-smi || true'
```

## 6) PyTorch ROCm environment

Create and validate the ROCm venv:

```bash
sudo bash ./scripts/create_pytorch_venv_in_ct.sh --ctid 120 --venv-path /opt/rocm-pytorch-venv
```

This venv is the runtime for vLLM in this repo.

## 7) Backend-specific tuning

Install all backends:

```bash
sudo bash ./scripts/manage_llm_backends_in_ct.sh --ctid 120 --action install --backend all --venv-path /opt/rocm-pytorch-venv
```

### 7.1 vLLM tuning

Edit `/etc/default/vllm` in the CT:

```bash
pct exec 120 -- bash -lc 'cat >/etc/default/vllm <<EOF
VLLM_MODEL=/opt/models/your-model
VLLM_PORT=8000
EOF'
```

Then tune service args in `vllm.service` (common ROCm-friendly options):

- `--dtype bfloat16`
- `--gpu-memory-utilization 0.85` to `0.92`
- `--max-model-len` sized to workload

Restart:

```bash
pct exec 120 -- systemctl restart vllm
```

### 7.2 Ollama tuning

Create `/etc/systemd/system/ollama.service.d/override.conf` in CT with environment overrides:

- `OLLAMA_NUM_PARALLEL`
- `OLLAMA_MAX_LOADED_MODELS`
- `OLLAMA_KEEP_ALIVE`

Then:

```bash
pct exec 120 -- bash -lc 'systemctl daemon-reload && systemctl restart ollama'
```

### 7.3 llama.cpp tuning

For ROCm build, `llama-server` typically benefits from:

- `-ngl 999` (offload all possible layers)
- `-c` context sized for your model + prompt needs
- batch params tuned to latency vs throughput goals

Service file in this repo already builds with `-DGGML_HIP=ON`.

## 8) Stability guardrails

- Keep CT swap minimal; prioritize avoiding host swap entirely.
- Don’t run all backends with large models simultaneously at first.
- Start with one backend/model, record baseline, then scale concurrency.
- Watch thermals: sustained LPDDR5X bandwidth and iGPU clocks are heat-sensitive.

## 9) Benchmark and iterate loop

1. Start one backend and one model.
2. Measure tokens/sec + latency at fixed prompt size.
3. Adjust one variable at a time:
   - CPU cores
   - memory allocation
   - backend concurrency
   - model quantization / context length
4. Keep notes and lock the best stable profile.

## 10) Health and diagnostics

Toolkit checks:

```bash
sudo bash ./scripts/test_llm_backends_in_ct.sh --ctid 120 --backend all --verbose
```

Manual service logs:

```bash
pct exec 120 -- systemctl status vllm --no-pager
pct exec 120 -- systemctl status ollama --no-pager
pct exec 120 -- systemctl status llama-cpp --no-pager
pct exec 120 -- journalctl -u vllm -n 100 --no-pager
```

## 11) Recommended starting profile (your hardware)

Use this as a practical first pass:

- CT: 16 vCPU, 96GB RAM, swap 0
- vLLM: BF16, memory utilization ~0.9
- Ollama: low parallelism initially (1-2)
- llama.cpp: ROCm build, full layer offload where model allows
- One active large model at a time until baseline is stable

After baseline, scale concurrency carefully and monitor OOM behavior.
