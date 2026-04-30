# SUSE Edge: K3s + NVIDIA GPU on SL Micro 6.2 (EIB + Metal3)

Edge Image Builder (EIB) configuration plus Metal3 provisioning glue for
deploying SUSE Linux Micro 6.2 + K3s + NVIDIA GPU stack across a fleet of
bare-metal nodes.

The EIB image is **generic** — no per-node data baked in. Per-node static IPs,
hostnames, and BMC details flow through Metal3 at provisioning time. See
[`docs/ADR-001`](docs/ADR-001-network-configuration-injection.md) for the full
architecture rationale.

## Prerequisites

- **Podman** or **Docker**
- **[Task](https://taskfile.dev/installation/)** for the task aliases
- **SUSE Customer Center subscription** — registration code in
  `secrets/scc-registration-code` (git-ignored). Required for signed NVIDIA drivers.
- **Base image** — `SL-Micro.x86_64-6.2-Base-GM.raw` in `base-images/`
  (download from SCC; xz-compressed, run `unxz` first).
- **Management cluster** for the deploy step — RKE2 + Rancher + MetalLB +
  Ironic + BMO + CAPM3. Out of scope for this repo.
- **Ansible** + collections for `task register-nodes`:
  ```bash
  ansible-galaxy collection install -r ansible/requirements.yml
  ```

## Build the image

```bash
task validate        # syntax-check the EIB definition
task build           # build the raw image (--privileged required for package resolution)
task generate        # generate a combustion test drive
task logs            # tail logs from the most recent build
task clean           # remove _build/, _validation/, _definition-resolved.yaml
```

The Taskfile injects `secrets/scc-registration-code` into `definition.yaml.tmpl`
via `envsubst` to produce `_definition-resolved.yaml` before invoking EIB. The
SCC code never lands in `definition.yaml.tmpl` or git history.

## Register nodes with Metal3

With a management cluster running and `KUBECONFIG` pointing at it:

```bash
task register-nodes              # all nodes in inventory
task register-nodes -- node01    # single node
```

For each node this creates:
- `<node>-bmc-credentials` Secret (Redfish auth)
- `<node>-networkdata` Secret (nmstate — IPA + deployed OS)
- `<node>` BareMetalHost CR (triggers Ironic provisioning)

Watch progress:
```bash
kubectl get baremetalhosts -n metal3-system
kubectl get baremetalhost <node> -n metal3-system -o jsonpath='{.status.provisioning.state}'
```

## Repo layout

```
definition.yaml.tmpl              EIB definition (raw image, ignition.platform.id=openstack kernel arg)
custom/scripts/
  01-fix-growfs.sh                grows root FS to full disk on first boot
  02-configure-network.sh         mounts config-2, applies nmstate via nmc, sets hostname
kubernetes/
  config/server.yaml              K3s server config (CNI, SELinux)
  helm/values/                    NVIDIA device plugin Helm values
  manifests/                      RuntimeClass for the NVIDIA runtime
os-files/                         containerd config.toml.tmpl with the NVIDIA runtime handler
rpms/gpg-keys/                    pinned GPG keys (NVIDIA container toolkit, Rancher/K3s)
metal3/
  baremetalhost.j2                BareMetalHost CR (preprovisioningNetworkDataName + networkData)
  networkdata-secret.j2           nmstate Secret used by both networkData fields
ansible/
  inventory.yml                   per-node config — single source of truth
  playbooks/register-nodes.yml    creates Secrets + BareMetalHost CRs
  requirements.yml                community.general + kubernetes.core
secrets/                          git-ignored — SCC code, BMC passwords (bmc-<node>)
docs/ADR-001-…                    architecture decision record
```

## First-boot flow

1. EIB image is written to disk by Ironic.
2. Ironic writes `config-2` partition with `meta_data.json` (hostname) and
   `network_data.json` (nmstate from the BMH `networkData` Secret).
3. Combustion runs `custom/scripts/01-fix-growfs.sh` then
   `02-configure-network.sh`. The latter mounts config-2, sets the hostname
   from `metal3-name`, and runs `nmc generate && nmc apply` to materialize the
   NetworkManager connections.
4. K3s starts with the configured network and correct hostname.

## References

- [SUSE Edge 3.5 — Metal3 quickstart](https://documentation.suse.com/suse-edge/3.5/html/edge/quickstart-metal3.html)
- [SUSE Edge 3.5 — NVIDIA on SL Micro](https://documentation.suse.com/suse-edge/3.5/html/edge/id-nvidia-gpus-on-suse-linux-micro.html)
- [Edge Image Builder repo](https://github.com/suse-edge/edge-image-builder)
- [NM Configurator (`nmc`)](https://github.com/suse-edge/nm-configurator)
