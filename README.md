# SUSE Edge Image Builder: K3s + NVIDIA (SL Micro 6.2)

This repository contains the Edge Image Builder (EIB) configuration for building a SUSE Linux Micro 6.2 image with K3s and NVIDIA GPU support.

## 🚀 Build Instructions

### Prerequisites
- **Podman** or **Docker** installed.
- **[Task](https://taskfile.dev/installation/)** (optional) for convenient task aliases.
- **SUSE Customer Center (SCC) Subscription:** Required for signed NVIDIA drivers.
- **SCC registration code** stored in `secrets/scc-registration-code` (git-ignored).
- **Base ISO:** [Download SLE Micro 6.2](https://www.suse.com/download/sle-micro/) and place it in `base-images/`.

### With Taskfile (recommended)

```bash
task validate   # Inject SCC code and validate the definition
task build      # Inject SCC code and build the image
task generate   # Generate a combustion test drive
task logs       # Tail logs from the most recent build
task clean      # Remove _build/ and _validation/ output
```

### Manual Commands

The Taskfile injects `secrets/scc-registration-code` into `definition.yaml.tmpl` to produce `_definition-resolved.yaml` before calling EIB. To do this manually:

```bash
SCC_REG_CODE=$(cat secrets/scc-registration-code) \
  envsubst '${SCC_REG_CODE}' < definition.yaml.tmpl > _definition-resolved.yaml
```

**Validate:**
```bash
podman run --rm -i \
  -v "$(pwd)":/eib \
  registry.suse.com/edge/3.5/edge-image-builder:1.3.3 \
  validate --definition-file _definition-resolved.yaml
```

**Build** (`--privileged` required for package resolution):
```bash
podman run --rm -i --privileged \
  -v "$(pwd)":/eib \
  registry.suse.com/edge/3.5/edge-image-builder:1.3.3 \
  build --definition-file _definition-resolved.yaml
```

**Generate** a combustion drive for testing:
```bash
podman run --rm -i --privileged \
  -v "$(pwd)":/eib \
  registry.suse.com/edge/3.5/edge-image-builder:1.3.3 \
  generate --definition-file _definition-resolved.yaml \
  --arch x86_64 --output-type iso --output combustion-test.iso
```

## 📂 Structure
- `definition.yaml.tmpl`: Main EIB configuration template — `${SCC_REG_CODE}` is substituted at build time.
- `base-images/`: Base ISO(s) — git-ignored, must be downloaded manually.
- `os-files/`: Containerd runtime configuration template for the NVIDIA runtime handler.
- `kubernetes/config/server.yaml`: K3s server config (CNI, SELinux).
- `kubernetes/helm/values/nvidia-device-plugin.yaml`: Helm values for the NVIDIA device plugin chart.
- `kubernetes/manifests/nvidia-runtime-class.yaml`: RuntimeClass enabling pods to request the NVIDIA runtime.
- `combustion/`: First-boot script (enables nvidia-container-toolkit service).
- `secrets/`: Git-ignored directory for the SCC registration code.

## 🔒 Privacy & Safety
- **SCC Credentials:** Store your key in `secrets/scc-registration-code` (git-ignored). The Taskfile injects it at build time via `envsubst` — it never touches `definition.yaml.tmpl` or git history.

## 📚 References
- [Official SUSE Edge Image Builder Repository](https://github.com/suse-edge/edge-image-builder)
- [Official Docs: NVIDIA GPUs on SUSE Linux Micro (SUSE Edge 3.5)](https://documentation.suse.com/suse-edge/3.5/html/edge/id-nvidia-gpus-on-suse-linux-micro.html)
- [Fuel Ignition](https://opensuse.github.io/fuel-ignition/) — web UI for generating Ignition/Combustion configs

## 🦎 AIcko's Arch Note
Updated for **SL Micro 6.2**. This build ensures the NVIDIA runtime is baked into the immutable OS layer, providing consistent GPU availability across reboots.
