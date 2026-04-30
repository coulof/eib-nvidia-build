# ADR-001: Network Configuration Injection for SUSE Edge at Scale

**Status:** Accepted
**Date:** 2026-04-30
**Deciders:** Lead Architect, Infrastructure Engineering Team

---

## Context

Deploying SUSE Edge nodes at scale requires a way to deliver per-node network
configuration (static IPs, hostnames) to immutable SL Micro 6.2 images without
baking node-specific data into the image itself. The constraints:

- **No DHCP** on the target network — nodes must come up with static IPs from first boot
- **BMC (iLO/iDRAC) reachable** on a separate management network
- **Fleet scale** — hardware replacement (RMA) and multi-site deployment must not
  require image rebuilds

---

## Options Considered

### Option A: Monolithic Multi-Profile Image (EIB MAC-match)

A single EIB image embedding per-MAC NetworkManager profiles for the whole fleet.

| Dimension | Assessment |
|---|---|
| Complexity | Low (single build) |
| Scalability | Medium (image size grows with node count) |
| Hardware dependency | High (bound to specific MACs) |
| Maintenance | High (RMA requires image rebuild) |

**Rejected** — brittle, leaks topology into the image, unworkable across sites.

### Option B: Ansible + Redfish per-node combustion ISO injection

A second virtual-media ISO per node containing only the NMConnection + hostname,
mounted via Redfish and consumed by combustion.

| Dimension | Assessment |
|---|---|
| Complexity | Medium (BMC + Ansible) |
| Scalability | Medium (inventory-driven, but imperative) |
| GitOps fit | Poor — no reconciliation, no node-state machine |
| SUSE alignment | Partial — uses Redfish but bypasses the SUSE-recommended stack |

**Rejected** — works for a single cluster but does not integrate with Cluster API,
has no node-state visibility, and requires a manual ISO HTTP server. Code for this
option lived under `templates/`, `ansible/playbooks/generate-and-inject.yml`, and
`task deploy`; all removed in favour of Option C.

### Option C: Metal3 / Ironic with EIB `custom/scripts/` (Adopted)

SUSE Edge ships Metal3 as the native bare-metal provisioning stack. EIB builds a
generic, hardware-agnostic raw image; per-node config is delivered through Metal3
(Ironic) at provisioning time.

| Dimension | Assessment |
|---|---|
| Complexity | High — requires management cluster (RKE2 + Rancher + MetalLB + Ironic + BMO + CAPM3) |
| Scalability | Maximum — declarative, self-healing, Cluster API native |
| Hardware dependency | None |
| GitOps fit | Excellent — BareMetalHost CRDs in git, Fleet-compatible |
| SUSE alignment | Native — the documented production path |

---

## Decision

Adopt **Option C (Metal3)**. EIB produces one generic raw image; per-node config
flows through `BareMetalHost` Secrets and is applied at first boot by an
EIB-bundled script.

---

## Architecture

The end-to-end flow combines four moving parts. Understanding each is necessary
before reading the implementation files.

### 1. EIB image (`task build`)

EIB produces a single raw image (`SL-Micro.x86_64-6.2-Base-GM.raw` →
`edge-nvidia-k3s-slmicro62.raw`) containing:

- SL Micro 6.2 with K3s + NVIDIA stack baked in
- Kernel argument **`ignition.platform.id=openstack`** — mandatory; without it
  SL Micro will not consume cloud-init/openstack metadata from the config drive
- `custom/scripts/01-fix-growfs.sh` — grows root FS to full disk size
- `custom/scripts/02-configure-network.sh` — applies per-node network config
  from `config-2` (see step 4)

EIB auto-bundles `custom/scripts/*` into the combustion archive and runs them
at first boot in numeric order.

### 2. Metal3 provisioning (`task register-nodes`)

For each node, the Ansible playbook creates three Kubernetes objects in the
management cluster:

| Object | Content | Purpose |
|---|---|---|
| `<node>-bmc-credentials` Secret | username/password | Used by Ironic to talk Redfish |
| `<node>-networkdata` Secret | nmstate YAML (interface, IP, routes, DNS) | Static IP for IPA ramdisk + deployed OS |
| `<node>` BareMetalHost CR | references both Secrets, points at the EIB image URL | Triggers Ironic |

Ironic then:
1. Mounts the IPA boot ISO via Redfish virtual media
2. Applies the `preprovisioningNetworkDataName` nmstate during inspection (DHCP-less)
3. Writes the EIB raw image to disk
4. Writes a `config-2`-labeled partition containing `meta_data.json` (with the
   `metal3-name` field) and `network_data.json` (nmstate from the same Secret,
   referenced via `spec.networkData`)
5. Reboots the node into the deployed OS

### 3. First boot — combustion runs `custom/scripts/`

Combustion runs `01-fix-growfs.sh`, then `02-configure-network.sh`. The script:

1. Looks for a partition with label `config-2`. If none, exits 0.
2. Mounts it read-only.
3. Reads `metal3-name` from `meta_data.json` → writes `/etc/hostname`.
4. Copies `network_data.json` to `/tmp/nmc/desired/_all.yaml`.
5. Runs `nmc generate` + `nmc apply` — translates nmstate into NetworkManager
   connection files and activates them.

After combustion completes, K3s starts with a configured network and correct hostname.

### 4. Why both `preprovisioningNetworkDataName` AND `networkData`?

These cover two different boot phases:

| BareMetalHost field | Consumed by | Phase |
|---|---|---|
| `preprovisioningNetworkDataName` | IPA ramdisk (Ironic Python Agent) | Inspection / provisioning |
| `networkData` | Written to `config-2` on the deployed disk by Ironic | Deployed OS first boot |

Both reference the **same Secret** (`<node>-networkdata`).

**Note on SUSE Edge's "networkData not supported" wording.** The SUSE Edge 3.5
quickstart-metal3 documentation states that "the IPAM resources and
`Metal3DataTemplate` networkData fields are not currently supported." This refers
specifically to the **IPAM-templated** networkData (auto-populated by the IPAM
controller from a pool). A **manually-set `BareMetalHost.spec.networkData`
Secret reference** is not in the explicit-support list, but is the only Ironic
mechanism documented for placing `network_data.json` onto the deployed OS's
`config-2` partition — and SUSE's own example `configure-network.sh` script
relies on that file existing. We therefore set it manually and treat it as
working until SUSE's docs say otherwise.

---

## Consequences

- **Easier:** Hardware replacement — update `BareMetalHost` CR + Secret; Metal3 reprovisions
- **Easier:** Node lifecycle visibility via `kubectl get baremetalhosts`
- **Easier:** GitOps via Fleet — CRDs in git, applied declaratively
- **Harder:** Requires a management cluster (RKE2 + Rancher + MetalLB + Ironic + BMO + CAPM3) before any node can be provisioned
- **Unchanged:** EIB image build (`task build`), NVIDIA stack, K3s configuration

---

## Implementation

| Artifact | Role |
|---|---|
| `definition.yaml.tmpl` | EIB raw image — `imageType: raw`, `kernelArgs: [ignition.platform.id=openstack]` |
| `custom/scripts/01-fix-growfs.sh` | Grows root FS on first boot |
| `custom/scripts/02-configure-network.sh` | Mounts config-2, applies nmstate via `nmc`, sets hostname |
| `metal3/baremetalhost.j2` | BareMetalHost CR — references both `preprovisioningNetworkDataName` and `networkData` |
| `metal3/networkdata-secret.j2` | nmstate Secret — single source for IPA + deployed OS |
| `ansible/inventory.yml` | Per-node variables (BMC, IP, MAC, hostname) |
| `ansible/playbooks/register-nodes.yml` | Creates BMC creds Secret, networkdata Secret, BareMetalHost CR |
| `task register-nodes [-- node]` | Taskfile entry point |

---

## Action Items

1. [x] Generic EIB image — no per-node profiles baked in
2. [x] `custom/scripts/01-fix-growfs.sh`
3. [x] `custom/scripts/02-configure-network.sh`
4. [x] `metal3/baremetalhost.j2` references both networkData fields
5. [x] `ansible/playbooks/register-nodes.yml`
6. [ ] Verify `nmc` binary is present in the SL Micro 6.2 base image, or bundle it via EIB (`packageList` or `custom/files/`). SUSE's reference script invokes `./nmc` from CWD; ours assumes `nmc` is on `$PATH`.
7. [ ] Download `SL-Micro.x86_64-6.2-Base-GM.raw` to `base-images/` (only the SelfInstall ISOs are present today)
8. [ ] Deploy management cluster (RKE2 + Rancher + MetalLB + Ironic + BMO + CAPM3) — out of scope for this repo
9. [ ] First end-to-end provisioning test — confirm that `network_data.json` lands on the deployed OS's `config-2` and that `02-configure-network.sh` consumes it correctly
