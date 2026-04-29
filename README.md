# SUSE Edge Image Builder: K3s + NVIDIA

This repository contains the Edge Image Builder (EIB) configuration for building a SUSE Linux Micro 6.1 image with K3s and NVIDIA GPU support.

## 🚀 Build Instructions

### Prerequisites
- **Podman** or **Docker** installed.
- **SUSE Customer Center (SCC) Subscription:** Required for signed NVIDIA drivers.
- **Base ISO:** Place `SL-Micro.x86_64-6.1-Base-SelfInstall-GM.install.iso` in this directory (or update `definition.yaml`).

### Build Command
Run the build from this directory:

```powershell
podman run --rm -it --privileged `
  -v ${PWD}:/eib `
  registry.suse.com/edge/edge-image-builder:1.3.3 `
  build --definition-file definition.yaml
```

## 📂 Structure
- `definition.yaml`: Main configuration (packages, repos, k3s version).
- `os-files/`: Custom configuration templates for `containerd`.
- `kubernetes/manifests/`: K8s resources for the NVIDIA Device Plugin and RuntimeClass.

## 🔒 Privacy & Safety
- **SCC Credentials:** If you use a `combustion` script with registration codes, **DO NOT** commit it. Use a `.env` file or local un-tracked files for secrets.
- **Base ISOs:** ISO files are large and should be ignored (see `.gitignore`).

## 🦎 AIcko's Arch Note
This build ensures the NVIDIA runtime is baked into the immutable OS layer of SL Micro, providing consistent GPU availability across reboots.
