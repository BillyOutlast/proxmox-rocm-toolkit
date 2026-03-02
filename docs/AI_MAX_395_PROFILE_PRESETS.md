# AMD AI Max+ 395 Profile Presets

Target: AMD AI Max+ 395, Radeon 8060S, 128GB LPDDR5X-8000, Proxmox + Ubuntu 24.04 LXC + ROCm 7.2

Use these presets after your base stack is working:

- [Base optimization guide](AI_MAX_395_PROXMOX_OPTIMIZATION.md)

## 1) Preset summary

| Preset | Goal | CT vCPU | CT RAM | Swap | Backend parallelism |
|---|---|---:|---:|---:|---|
| Max Throughput | Highest tokens/sec | 16 | 104GB | 0 | High |
| Balanced | Best all-around stability | 14 | 96GB | 0 | Medium |
| Low Noise | Lower thermals/acoustics | 10 | 80GB | 0-4GB | Low |

## 2) CT resource presets

Apply from Proxmox host (example CTID `120`):

### Max Throughput

```bash
pct set 120 --cores 16 --memory 106496 --swap 0
```

### Balanced

```bash
pct set 120 --cores 14 --memory 98304 --swap 0
```

### Low Noise

```bash
pct set 120 --cores 10 --memory 81920 --swap 4096
```

## 3) vLLM presets

These examples assume vLLM installed in `/opt/rocm-pytorch-venv`.

### 3.1 Max Throughput

```bash
pct exec 120 -- bash -lc 'cat >/etc/default/vllm <<EOF
VLLM_MODEL=/opt/models/your-model
VLLM_PORT=8000
EOF'

pct exec 120 -- bash -lc 'cat >/etc/systemd/system/vllm.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/bin/bash -lc "/opt/rocm-pytorch-venv/bin/python -m vllm.entrypoints.openai.api_server --host 0.0.0.0 --port 8000 --model \\\"\\${VLLM_MODEL}\\\" --dtype bfloat16 --gpu-memory-utilization 0.92 --max-model-len 8192"
EOF
systemctl daemon-reload
systemctl restart vllm'
```

### 3.2 Balanced

```bash
pct exec 120 -- bash -lc 'cat >/etc/systemd/system/vllm.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/bin/bash -lc "/opt/rocm-pytorch-venv/bin/python -m vllm.entrypoints.openai.api_server --host 0.0.0.0 --port 8000 --model \\\"\\${VLLM_MODEL}\\\" --dtype bfloat16 --gpu-memory-utilization 0.88 --max-model-len 6144"
EOF
systemctl daemon-reload
systemctl restart vllm'
```

### 3.3 Low Noise

```bash
pct exec 120 -- bash -lc 'cat >/etc/systemd/system/vllm.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/bin/bash -lc "/opt/rocm-pytorch-venv/bin/python -m vllm.entrypoints.openai.api_server --host 0.0.0.0 --port 8000 --model \\\"\\${VLLM_MODEL}\\\" --dtype bfloat16 --gpu-memory-utilization 0.82 --max-model-len 4096"
EOF
systemctl daemon-reload
systemctl restart vllm'
```

## 4) Ollama presets

Create service overrides in CT:

### Max Throughput

```bash
pct exec 120 -- bash -lc 'mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment=OLLAMA_NUM_PARALLEL=3
Environment=OLLAMA_MAX_LOADED_MODELS=2
Environment=OLLAMA_KEEP_ALIVE=20m
EOF
systemctl daemon-reload
systemctl restart ollama'
```

### Balanced

```bash
pct exec 120 -- bash -lc 'mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment=OLLAMA_NUM_PARALLEL=2
Environment=OLLAMA_MAX_LOADED_MODELS=2
Environment=OLLAMA_KEEP_ALIVE=10m
EOF
systemctl daemon-reload
systemctl restart ollama'
```

### Low Noise

```bash
pct exec 120 -- bash -lc 'mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment=OLLAMA_NUM_PARALLEL=1
Environment=OLLAMA_MAX_LOADED_MODELS=1
Environment=OLLAMA_KEEP_ALIVE=5m
EOF
systemctl daemon-reload
systemctl restart ollama'
```

## 5) llama.cpp presets

Tune `/etc/default/llama-cpp` in CT:

### Max Throughput

```bash
pct exec 120 -- bash -lc 'cat >/etc/default/llama-cpp <<EOF
LLAMA_MODEL=/opt/models/your-model.gguf
LLAMA_PORT=8080
LLAMA_CTX=8192
EOF
systemctl restart llama-cpp'
```

### Balanced

```bash
pct exec 120 -- bash -lc 'cat >/etc/default/llama-cpp <<EOF
LLAMA_MODEL=/opt/models/your-model.gguf
LLAMA_PORT=8080
LLAMA_CTX=6144
EOF
systemctl restart llama-cpp'
```

### Low Noise

```bash
pct exec 120 -- bash -lc 'cat >/etc/default/llama-cpp <<EOF
LLAMA_MODEL=/opt/models/your-model.gguf
LLAMA_PORT=8080
LLAMA_CTX=4096
EOF
systemctl restart llama-cpp'
```

## 6) Validate after applying a preset

```bash
sudo bash ./scripts/test_llm_backends_in_ct.sh --ctid 120 --backend all --verbose
```

## 7) Rollback

If a preset is too aggressive:

1. Move one level down (Max -> Balanced -> Low Noise).
2. Reduce concurrent requests first.
3. Lower context length before changing model quantization.
