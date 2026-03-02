# Proxmox ROCm LXC Toolkit

Toolkit for building an **unprivileged Ubuntu 24.04 LXC** on Proxmox and installing **ROCm 7.2** with AMD's official Ubuntu package-manager method.

## What this includes

- `scripts/create_rocm_lxc.sh`
	- Creates an unprivileged Ubuntu 24.04 container using community-scripts `ct/ubuntu.sh`.
- `scripts/configure_gpu_passthrough.sh`
	- Adds `/dev/kfd` + `/dev/dri` passthrough and cgroup permissions in LXC config.
- `scripts/install_rocm_in_ct.sh`
	- Registers ROCm 7.2 `noble` apt repos and installs a chosen ROCm meta package.

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

sudo ./scripts/create_rocm_lxc.sh \
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
sudo ./scripts/configure_gpu_passthrough.sh --ctid 120
```

3) Install ROCm in container:

```bash
sudo ./scripts/install_rocm_in_ct.sh --ctid 120 --package rocm
```

4) Optional manual checks:

```bash
pct exec 120 -- bash -lc '/opt/rocm/bin/rocminfo | head -n 40'
pct exec 120 -- bash -lc '/opt/rocm/bin/rocm-smi || true'
```

## ROCm package options

`install_rocm_in_ct.sh` defaults to `rocm`, but you can pass alternatives, for example:

- `rocm-hip-runtime`
- `rocm-opencl-runtime`
- `rocm-ml-libraries`

Example:

```bash
sudo ./scripts/install_rocm_in_ct.sh --ctid 120 --package rocm-hip-runtime
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
