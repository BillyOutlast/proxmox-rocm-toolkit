# Ollama ROCm Troubleshooting (Proxmox LXC)

This guide is for the toolkit setup in this repo:

- Unprivileged Ubuntu 24.04 LXC on Proxmox
- ROCm-enabled GPU passthrough
- Ollama managed by systemd (service user `llm-svc`)

## Quick triage checklist

Run these first in the CT:

```bash
systemctl status ollama --no-pager
systemctl show ollama -p User,Group,SupplementaryGroups,Environment --no-pager
journalctl -u ollama -n 200 --no-pager
ss -ltnp | grep 11434 || true
```

From another machine:

```bash
curl http://<ct-ip>:11434/api/tags
```

## Symptom: Open WebUI can connect, but model load fails with 500

Typical log pattern:

- `library=ROCm` is detected
- then `ROCm error: out of memory`
- then `model failed to load`

### Why this happens

Ollama can detect ROCm correctly but still OOM during model graph/KV allocation, often due to high context size or aggressive defaults.

### Fix

One-command helper from the Proxmox host:

```bash
sudo bash ./scripts/set_ollama_memory_profile_in_ct.sh --ctid <ctid>
```

Preset examples:

```bash
sudo bash ./scripts/set_ollama_memory_profile_in_ct.sh --ctid <ctid> --preset safe
sudo bash ./scripts/set_ollama_memory_profile_in_ct.sh --ctid <ctid> --preset balanced
sudo bash ./scripts/set_ollama_memory_profile_in_ct.sh --ctid <ctid> --preset max
```

Preset selection quick guide:

| Model size (typical) | Suggested preset | Notes |
|---|---|---|
| 7B to 14B | `max` | Highest throughput, more aggressive memory/concurrency. |
| 20B to 32B | `balanced` | Best first choice for stability on large models. |
| 30B+ with load failures/OOM | `safe` | Use when `ROCm error: out of memory` appears. |

If a model fails to load, step down from `max` → `balanced` → `safe` before manual tuning.

Manual method:

Create a memory-tuning drop-in:

```bash
install -d /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/20-memory-tuning.conf <<'EOF'
[Service]
Environment=OLLAMA_CONTEXT_LENGTH=8192
Environment=OLLAMA_MAX_LOADED_MODELS=1
Environment=OLLAMA_NUM_PARALLEL=1
Environment=OLLAMA_FLASH_ATTENTION=false
EOF

systemctl daemon-reload
systemctl restart ollama
```

If still failing, reduce context further:

```bash
sed -i 's/OLLAMA_CONTEXT_LENGTH=8192/OLLAMA_CONTEXT_LENGTH=4096/' /etc/systemd/system/ollama.service.d/20-memory-tuning.conf
systemctl daemon-reload
systemctl restart ollama
```

Also reduce request-side settings in Open WebUI for that model:

- `num_ctx`: `4096` or `8192`
- `num_gpu`: start moderate (do not force maximum layer offload)
- concurrency: 1 request at a time

## Symptom: Ollama only uses CPU (`library=cpu`, `total_vram=0 B`)

### Checks

```bash
id llm-svc
ls -l /dev/kfd /dev/dri/renderD* 2>/dev/null || true
getent group video
getent group render
```

`llm-svc` must be in `video` and `render` groups and the devices must exist in the CT.

### Fix

```bash
usermod -aG video,render llm-svc
systemctl restart ollama
```

If devices are missing, re-run host passthrough script and restart CT:

```bash
sudo bash ./scripts/configure_gpu_passthrough.sh --ctid <ctid>
pct stop <ctid>
pct start <ctid>
```

## Symptom: API only listening on localhost

### Fix (host side helper)

```bash
sudo bash ./scripts/expose_ollama_in_ct.sh --ctid <ctid>
```

Custom bind/port:

```bash
sudo bash ./scripts/expose_ollama_in_ct.sh --ctid <ctid> --listen 0.0.0.0 --port 11434
```

Revert to defaults:

```bash
sudo bash ./scripts/close_ollama_network_in_ct.sh --ctid <ctid>
```

## Symptom: External network still cannot reach port 11434

### Checks

- Proxmox firewall rules at Datacenter/Node/CT levels
- CT firewall (`ufw`) if enabled
- Correct CT IP/subnet route from Open WebUI host

### Minimal firewall rules

In CT (if `ufw` is used):

```bash
ufw allow from <LAN_CIDR> to any port 11434 proto tcp
```

## Log line: `failed to parse CPU allowed micro secs` in LXC

This warning is common in containers where cgroup CPU quota reports `max`. It is usually non-fatal and not the root cause if ROCm is detected and only model load fails.

## Recommended stable baseline for large models

Start conservative, then scale up:

- `OLLAMA_CONTEXT_LENGTH=4096` to `8192`
- `OLLAMA_NUM_PARALLEL=1`
- `OLLAMA_MAX_LOADED_MODELS=1`
- one active large model at a time

Then monitor:

```bash
journalctl -u ollama -f
```

Look for successful `loading model` and absence of `ROCm error: out of memory`.

## Security note

Ollama has no built-in authentication by default. If exposed beyond localhost, restrict by firewall or place behind an authenticated reverse proxy.
