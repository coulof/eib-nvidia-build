# ADR-001: Scalable Network Configuration Injection for SUSE Edge

**Status:** Accepted
**Date:** 2026-04-29
**Deciders:** Lead Architect, Infrastructure Engineering Team

---

## Context

Deploying SUSE Edge at scale requires a Zero-Touch or Low-Touch provisioning model. A "chicken and egg" problem arises when nodes boot without a DHCP server and require static network configuration (IPs, Bonds, VLANs) to reach the management plane (Rancher/Fleet). Edge Image Builder (EIB) can bake configurations into the image, but doing so creates tight coupling between software artifacts and physical hardware (MAC addresses), complicating hardware replacement (RMA) and mass deployment.

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

Metal3 is the SUSE Edge-recommended bare-metal provisioning stack. It uses Redfish under the hood and provides a Kubernetes-native declarative API (BareMetalHost CRDs) with full lifecycle state management. It is the correct long-term architecture for fleet-scale provisioning.

| Dimension | Assessment |
|---|---|
| Complexity | High (management cluster + Ironic + BMO + CAPM3 + MetalLB) |
| Scalability | **Maximum** — declarative, self-healing, Cluster API native |
| Hardware dependency | None |
| GitOps fit | Excellent |
| SUSE alignment | Native |

**Pros:** Full node lifecycle management; GitOps-ready; hardware-agnostic; Cluster API integration.

**Cons — and why we cannot adopt it today:**

1. **Single-ISO constraint.** Metal3's `BareMetalHost` spec exposes exactly one `spec.image` field. Ironic mounts one provisioning ISO per cycle. SL Micro's combustion mechanism requires a **second** block device labeled `COMBUSTION` to deliver per-node network configuration (NMConnection files, hostname). There is no equivalent of a second virtual media slot in the Metal3/Ironic workflow; per-node config must instead ride through the Ironic metadata service as ignition `userData`.

2. **Mandatory DHCP during provisioning.** The Ironic Python Agent (IPA) — the in-memory agent that runs during provisioning — must obtain an IP via DHCP to call back to Ironic and receive instructions. In an environment with **no DHCP** there is no fallback; IPA cannot boot into a useful state and provisioning times out. This is a hard constraint, independent of the workload network's IP model.

The combination of these two blockers makes Metal3 unsuitable for our current target environment. When DHCP becomes available on the provisioning network, Metal3 should replace this solution.

---

### Option C: Automated Virtual Media Injection via Ansible + Redfish ✅ Adopted

The BMC is reachable on the out-of-band management network. Redfish supports mounting **multiple** virtual media devices. This is leveraged to deliver two ISOs:

| ISO | Content | Purpose |
|---|---|---|
| Main EIB ISO | SL Micro + K3s + NVIDIA stack | Full OS installation |
| Per-node combustion ISO | NMConnection file + hostname script | Static IP and hostname at first boot |

The OS boots from the main ISO; combustion reads the labeled block device (the second ISO) before networking starts, setting the static IP and hostname before any service attempts to reach the network.

| Dimension | Assessment |
|---|---|
| Complexity | Medium (BMC + Ansible) |
| Scalability | High (inventory-driven, no image rebuild per node) |
| Hardware dependency | Low (generic OS image; config lives in inventory) |
| Maintenance | Low (RMA = update inventory, re-run playbook) |
| DHCP requirement | **None** — config is delivered out-of-band via BMC |

**Pros:** Works in zero-DHCP environments; OS image stays generic and immutable; uses existing BMC infrastructure; node variables are the single source of truth in Ansible inventory.
**Cons:** Imperative, no self-healing reconciliation. Does not integrate natively with Cluster API.

---

## Decision

Adopt **Option C** (Ansible + Redfish dual virtual media) as the initial provisioning mechanism.

Option B (Metal3) is the correct target architecture at fleet scale and should be adopted once DHCP is available on the provisioning network. When that transition happens, this ADR will be superseded.

---

## Consequences

- **Easier:** Hardware replacement — update MAC/IP/hostname in `ansible/inventory.yml`, re-run `task deploy`
- **Harder:** No automatic reconciliation if a node drifts; requires an operator to re-run the playbook
- **Deferred:** IPAM, full lifecycle state management, Cluster API integration — all blocked on Metal3 adoption
- **Revisit trigger:** Availability of DHCP on the provisioning network → migrate to Metal3

---

## Implementation

| Artifact | Role |
|---|---|
| `definition.yaml.tmpl` | Generic EIB definition — no node-specific config baked in |
| `templates/nmconnection.j2` | Jinja2 template → NMConnection static IP config |
| `templates/combustion-script.j2` | Jinja2 template → hostname script |
| `templates/definition-network.yaml` | Minimal EIB definition for `generate` (combustion ISO only) |
| `ansible/inventory.yml` | Single source of truth for all node variables |
| `ansible/playbooks/generate-and-inject.yml` | Renders templates, generates combustion ISO via EIB, injects both ISOs via Redfish, boots node |
| `task deploy [-- node]` | Taskfile entry point |

## Action Items

1. [x] Generic EIB image — no node-specific network profiles
2. [x] Ansible playbook using `community.general.redfish_command` for dual virtual media injection
3. [x] Per-node config managed exclusively through `ansible/inventory.yml`
4. [ ] Revisit Metal3 adoption once DHCP is available on the provisioning network
