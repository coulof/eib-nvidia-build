# SUSE Edge Image Builder: K3s + NVIDIA (SL Micro 6.2)

This repository contains the Edge Image Builder (EIB) configuration for building a SUSE Linux Micro 6.2 image with K3s and NVIDIA GPU support.

## 🚀 Build Instructions

### Prerequisites
- **Podman** or **Docker** installed.
- **SUSE Customer Center (SCC) Subscription:** Required for signed NVIDIA drivers.
- **Base ISO:** [Download SLE Micro 6.2](https://www.suse.com/download/sle-micro/) and place `SL-Micro.x86_64-6.2-Base-SelfInstall-GM.install.iso` in this directory (or update `definition.yaml`).

### Build Command
Run the build from this directory:

```powershell
podman run --rm -it --privileged `
  -v ${PWD}:/eib `
  registry.suse.com/edge/edge-image-builder:1.3.3 `
  build --definition-file definition.yaml
```

## 📂 Structure
- `definition.yaml`: Main configuration (packages, repos, k3s version updated for SL Micro 6.2).
- `os-files/`: Custom configuration templates for `containerd`.
- `kubernetes/manifests/`: K8s resources for the NVIDIA Device Plugin and RuntimeClass.
- `combustion/`: Secure SCC registration script.

## 🔒 Privacy & Safety
- **SCC Credentials:** Subscription keys are handled via `secrets/scc-registration-code` (Git-ignored). **DO NOT** commit your key.

## 📚 References
- [Official SUSE Edge Image Builder Repository](https://github.com/suse-edge/edge-image-builder)
- [Official Docs: NVIDIA GPUs on SUSE Linux Micro (SUSE Edge 3.5)](https://documentation.suse.com/suse-edge/3.5/html/edge/id-nvidia-gpus-on-suse-linux-micro.html)

## 🦎 AIcko's Arch Note
Updated for **SL Micro 6.2**. This build ensures the NVIDIA runtime is baked into the immutable OS layer, providing consistent GPU availability across reboots.
