# Proxmox ROCm LXC Toolkit

Toolkit for building an **unprivileged Ubuntu 24.04 LXC** on Proxmox and installing **ROCm 7.2** with AMD's official Ubuntu package-manager method.

Hardware-specific tuning guide:

- [AMD AI Max+ 395 Proxmox Optimization](docs/AI_MAX_395_PROXMOX_OPTIMIZATION.md)
- [AMD AI Max+ 395 Profile Presets](docs/AI_MAX_395_PROFILE_PRESETS.md)

## What this includes

- `scripts/create_rocm_lxc.sh`
	- Creates an unprivileged Ubuntu 24.04 container using community-scripts `ct/ubuntu.sh`.
- `scripts/configure_gpu_passthrough.sh`
	- Adds `/dev/kfd` + `/dev/dri` passthrough and cgroup permissions in LXC config.
- `scripts/install_rocm_in_ct.sh`
	- Registers ROCm 7.2 `noble` apt repos and installs a chosen ROCm meta package.
- `scripts/create_pytorch_venv_in_ct.sh`
	- Creates a Python 3.12 venv in the CT and installs AMD ROCm 7.2 PyTorch wheels.
- `scripts/manage_llm_backends_in_ct.sh`
	- Installs/updates vLLM, Ollama, and llama.cpp and configures systemd services under a nologin service user.
- `scripts/test_llm_backends_in_ct.sh`
	- Runs health checks for vLLM, Ollama, and llama.cpp services/endpoints.

## Requirements

- Proxmox VE host with a working AMD GPU stack exposing:
	- `/dev/kfd`
	- `/dev/dri`
- Template and container storage names available in Proxmox (for example `local` and `local-lvm`).
- Run scripts on the Proxmox host as `root`.

## Quick start

1) Create unprivileged container:

```bash
chmod +x scripts/*.sh

sudo bash ./scripts/create_rocm_lxc.sh \
	--ctid 120 \
	--hostname rocm-ct \
	--template-storage local \
	--container-storage local-lvm
```

This script uses:

- `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/ubuntu.sh`
- (internally by that script) `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/ubuntu-install.sh`

2) Configure GPU passthrough on host:

```bash
sudo bash ./scripts/configure_gpu_passthrough.sh --ctid 120
```

3) Install ROCm in container:

```bash
sudo bash ./scripts/install_rocm_in_ct.sh --ctid 120 --package rocm
```

4) Optional manual checks:

```bash
pct exec 120 -- bash -lc '/opt/rocm/bin/rocminfo | head -n 40'
pct exec 120 -- bash -lc '/opt/rocm/bin/rocm-smi || true'
```

5) Create PyTorch ROCm venv in CT:

```bash
sudo bash ./scripts/create_pytorch_venv_in_ct.sh --ctid 120 --venv-path /opt/rocm-pytorch-venv
```

6) Install LLM backends + services in CT:

```bash
sudo bash ./scripts/manage_llm_backends_in_ct.sh --ctid 120 --action install --backend all --venv-path /opt/rocm-pytorch-venv
```

By default, this creates and uses `llm-svc` (`/usr/sbin/nologin`) for service execution.
You can override with `--service-user <name>`.

Update later:

```bash
sudo bash ./scripts/manage_llm_backends_in_ct.sh --ctid 120 --action update --backend all --venv-path /opt/rocm-pytorch-venv
```

Backend-specific examples:

```bash
sudo bash ./scripts/manage_llm_backends_in_ct.sh --ctid 120 --action install --backend vllm --venv-path /opt/rocm-pytorch-venv
sudo bash ./scripts/manage_llm_backends_in_ct.sh --ctid 120 --action install --backend ollama
sudo bash ./scripts/manage_llm_backends_in_ct.sh --ctid 120 --action install --backend llama-cpp
```

7) Test backend services/endpoints:

```bash
sudo bash ./scripts/test_llm_backends_in_ct.sh --ctid 120 --backend all
```

Verbose diagnostics on failures:

```bash
sudo bash ./scripts/test_llm_backends_in_ct.sh --ctid 120 --backend all --verbose
```

Test one backend only:

```bash
sudo bash ./scripts/test_llm_backends_in_ct.sh --ctid 120 --backend vllm
sudo bash ./scripts/test_llm_backends_in_ct.sh --ctid 120 --backend ollama
sudo bash ./scripts/test_llm_backends_in_ct.sh --ctid 120 --backend llama-cpp
```

## Expose Ollama to LAN

By default, Ollama may bind to localhost only. To expose it to your network from inside the CT:

```bash
pct exec 120 -- bash -lc 'install -d /etc/systemd/system/ollama.service.d'
pct exec 120 -- bash -lc 'cat >/etc/systemd/system/ollama.service.d/network.conf <<"EOF"
[Service]
Environment=OLLAMA_HOST=0.0.0.0:11434
EOF'
pct exec 120 -- bash -lc 'systemctl daemon-reload && systemctl restart ollama'
```

Verify bind address and test from another machine:

```bash
pct exec 120 -- bash -lc 'ss -ltnp | grep 11434 || true'
curl http://<ct-ip>:11434/api/tags
```

If unreachable, allow TCP/11434 in Proxmox firewall (Datacenter/Node/CT) and CT firewall (`ufw`) as needed.
Ollama has no built-in auth by default, so only expose on trusted networks or behind an authenticated reverse proxy.



## ROCm package options

`install_rocm_in_ct.sh` defaults to `rocm`, but you can pass alternatives, for example:

- `rocm-hip-runtime`
- `rocm-opencl-runtime`
- `rocm-ml-libraries`

Example:

```bash
sudo bash ./scripts/install_rocm_in_ct.sh --ctid 120 --package rocm-hip-runtime
```

## Notes for unprivileged LXC

- Device passthrough to unprivileged containers can be sensitive to host kernel/driver updates.
- If your workload runs as a non-root user inside the CT, ensure that user is in `video`/`render` groups:

```bash
pct exec 120 -- bash -lc 'usermod -aG video,render <your-user>'
```

- A CT restart is often required after changing LXC device mappings.

## Community scripts (direct usage)

If you want to run the upstream script directly (interactive), use:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/ubuntu.sh)"
```

Repository:

- https://github.com/community-scripts/ProxmoxVE

## Alignment with AMD docs

ROCm install flow follows AMD’s Ubuntu package-manager guidance for ROCm 7.2 and Ubuntu 24.04 (`noble`):

- GPG key to `/etc/apt/keyrings/rocm.gpg`
- `rocm/apt/7.2` + `graphics/7.2/ubuntu` apt repos
- apt preference pin (`Pin-Priority: 600`)

Reference:

- https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/install-methods/package-manager/package-manager-ubuntu.html
- https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installryz/native_linux/install-pytorch.html
- https://docs.vllm.ai/en/latest/getting_started/installation/gpu/
- https://docs.ollama.com/linux
- https://github.com/ggml-org/llama.cpp
