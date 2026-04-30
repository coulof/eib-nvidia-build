# ADR-001: Scalable Network Configuration Injection for SUSE Edge

**Status:** Accepted
**Date:** 2026-04-29
**Deciders:** Lead Architect, Infrastructure Engineering Team

---

## Context

Deploying SUSE Edge at scale requires a Zero-Touch or Low-Touch provisioning model. A "chicken
and egg" problem arises when nodes boot without a DHCP server and require static network
configuration (IPs, Bonds, VLANs) to reach the management plane (Rancher/Fleet). EIB can bake
configurations into the image, but doing so creates tight coupling between the OS artifact and
physical hardware (MAC addresses), complicating hardware replacement (RMA) and mass deployment.

The constraints we are designing for:

- **No DHCP** on the target network — nodes must have static IPs from first boot
- **BMC (iLO/iDRAC) available** on all nodes via an out-of-band management network
- **Fleet scale** — hardware replacement and multi-site deployment must not require OS image rebuilds

---

## Options Considered

### Option A: Monolithic Multi-Profile Image (EIB MAC-match)

| Dimension | Assessment |
|---|---|
| Complexity | Low (single build) |
| Scalability | Medium (image size grows with node count) |
| Hardware dependency | **High** (bound to specific MACs) |
| Maintenance | High (RMA requires image rebuild) |

**Pros:** No external infrastructure. Simple field procedure.
**Cons:** Brittle — replacing a NIC breaks automation. Exposes the full cluster network topology inside the ISO.

---

### Option B: Metal3 / Ironic (SUSE Edge native provisioning)

Metal3 is the SUSE Edge-recommended bare-metal provisioning stack. It uses Redfish under the hood
and provides a Kubernetes-native declarative API (BareMetalHost CRDs) with full lifecycle state
management. It is the correct long-term architecture for fleet-scale provisioning.

| Dimension | Assessment |
|---|---|
| Complexity | High (management cluster + Ironic + BMO + CAPM3 + MetalLB) |
| Scalability | **Maximum** — declarative, self-healing, Cluster API native |
| Hardware dependency | None |
| GitOps fit | Excellent |
| SUSE alignment | Native |

**Pros:** Full node lifecycle management; GitOps-ready; hardware-agnostic; Cluster API integration.

**Why we cannot adopt it today — two hard blockers:**

**Blocker 1 — Combustion label mismatch with Ironic config drive.**
Metal3/Ironic creates a config drive partition on the root disk, labeled **`config-2`** (OpenStack
format), containing user data at `/openstack/latest/user_data`. SL Micro's **combustion** looks
for a block device labeled **`COMBUSTION`** — it will never find the `config-2` partition. **Ignition**,
on the other hand, does recognise the OpenStack config drive format and would work. SL Micro
supports both combustion and ignition, but EIB images use combustion by default. Switching to
ignition-based first-boot would unblock Metal3, but requires changes to how EIB builds are
configured.

A `DataImage` CRD exists that can attach a non-bootable ISO as a second virtual media mount —
however it only activates **after** provisioning completes and requires a reboot, making it
unsuitable for first-boot network configuration.
*(Source: `metal3-docs/design/baremetal-operator/host-config-drive.md`,
`metal3-docs/docs/user-guide/src/bmo/instance_customization.md`,
`metal3-docs/design/baremetal-operator/bmh_non-bootable_iso.md`)*

**Blocker 2 — Resolved by SUSE Edge `preprovisioningNetworkDataName` + nmstate.**
SUSE Edge Metal3 documents a DHCP-less provisioning path using `preprovisioningNetworkDataName`
referencing a Kubernetes Secret in **nmstate format**. When Redfish virtual media boot is used,
Ironic embeds this nmstate config into the IPA boot ISO; the IPA ramdisk applies it before
contacting Ironic, eliminating the DHCP requirement entirely. The same Secret is referenced by
`spec.networkData` to write `/mnt/openstack/latest/network_data.json` on the config drive for
the deployed OS. **Blocker 2 is therefore resolved for environments using SUSE Edge Metal3 with
Redfish virtual media.**
*(Source: https://documentation.suse.com/suse-edge/3.5/html/edge/quickstart-metal3.html#id-configuring-static-ips)*

**Blocker 1 therefore remains the only open blocker:** EIB images must be switched from
combustion to ignition before Metal3 can be adopted.

---

### Option C: Automated Virtual Media Injection via Ansible + Redfish ✅ Adopted

The BMC is reachable on the out-of-band management network. Redfish supports mounting **multiple**
virtual media devices simultaneously. This is leveraged to deliver two ISOs:

| Virtual media | Content | Consumed by |
|---|---|---|
| Main EIB ISO | SL Micro + K3s + NVIDIA stack | OS installer |
| Per-node combustion ISO | NMConnection file + hostname script | SL Micro combustion at first boot |

The OS boots from the main ISO; combustion detects the `COMBUSTION`-labeled block device (the
second mounted ISO), reads the network config and hostname script, applies them before any service
attempts to reach the network, then ejects the combustion drive.

| Dimension | Assessment |
|---|---|
| Complexity | Medium (BMC + Ansible) |
| Scalability | High (inventory-driven, no image rebuild per node) |
| Hardware dependency | Low (generic OS image; config lives in inventory) |
| Maintenance | Low (RMA = update inventory, re-run `task deploy`) |
| DHCP requirement | **None** — delivered entirely out-of-band via BMC |

**Pros:** Works in zero-DHCP environments; OS image stays generic and immutable; uses existing BMC
infrastructure; Jinja2 templates + Ansible inventory are the single source of truth.

**Cons:** Imperative, no self-healing reconciliation. Does not integrate with Cluster API.

---

## Decision

Adopt **Option C** (Ansible + Redfish dual virtual media) as the provisioning mechanism.

Option B (Metal3) is the correct target architecture. The transition should be triggered when:

- DHCP is available on the provisioning network **and** a compatible IPA image is available
  (from SUSE Edge or built in-house), **or**
- SL Micro EIB images are reconfigured to use ignition instead of combustion for first-boot config

---

## Consequences

- **Easier:** Hardware replacement — update `ansible/inventory.yml`, re-run `task deploy`
- **Harder:** No automatic reconciliation; no Cluster API integration
- **Deferred:** Full lifecycle management, GitOps provisioning, IPAM — all pending Metal3 adoption
- **Revisit trigger:** DHCP available on provisioning network + SUSE Edge ships a DHCP-less IPA

---

## Implementation

| Artifact | Role |
|---|---|
| `definition.yaml.tmpl` | Generic EIB OS image — no node-specific network config baked in |
| `templates/nmconnection.j2` | Jinja2 → NMConnection static IP config (combustion ISO content) |
| `templates/combustion-script.j2` | Jinja2 → hostname script (combustion ISO content) |
| `templates/definition-network.yaml` | Minimal EIB definition for `generate` (combustion ISO only) |
| `ansible/inventory.yml` | Single source of truth for all node variables |
| `ansible/playbooks/generate-and-inject.yml` | Renders templates, generates combustion ISO via EIB, injects both ISOs via Redfish, boots node |
| `task deploy [-- node]` | Taskfile entry point |

## Action Items

1. [x] Generic EIB image — no per-node network profiles
2. [x] Ansible playbook using `community.general.redfish_command` for dual virtual media injection
3. [x] Per-node config managed exclusively through `ansible/inventory.yml`
4. [ ] Revisit Metal3 when DHCP is available on provisioning network or SUSE Edge ships a DHCP-less IPA
5. [ ] Evaluate switching EIB build from combustion to ignition — this would unlock full Metal3 compatibility and eliminate per-node ISO lifecycle entirely (config becomes a Kubernetes Secret)
