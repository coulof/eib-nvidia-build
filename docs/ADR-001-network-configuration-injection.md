# ADR-001: Scalable Network Configuration Injection for SUSE Edge

**Status:** Accepted
**Date:** 2026-04-29
**Deciders:** Lead Architect, Infrastructure Engineering Team

## Context
Deploying SUSE Edge at scale requires a "Zero-Touch" or "Low-Touch" provisioning model. The "chicken and egg" problem arises when nodes boot without a DHCP server and require static network configuration (IPs, Bonds, VLANs) to reach the management plane (Rancher/Fleet). While Edge Image Builder (EIB) can "bake" configurations into the image, doing so creates tight coupling between software artifacts and physical hardware (MAC addresses), complicating hardware replacement (RMA) and mass deployment.

## Decision
We propose adopting a **Decoupled Configuration Injection** model using **Automated Virtual Media (Redfish/Ansible)** as the primary strategy for Core/Industrial Edge, with a transition path toward **Zero-Touch Provisioning (IPv6 Link-Local)** for massive scale deployments. 

We explicitly reject "Individualized Images" and "Hardcoded MAC-to-IP mapping" within the base OS image to ensure architectural agility.

## Options Considered

### Option A: Monolithic Multi-Profile Image (EIB MAC-match)
| Dimension | Assessment |
|-----------|------------|
| Complexity | Low (Single build) |
| Scalability | Medium (Image size grows with node count) |
| Hardware Dependency | **High** (Bound to specific MACs) |
| Maintenance | High (RMA requires image rebuild) |

**Pros:**
- Simple "one-key-fits-all" for field technicians.
- No external infrastructure required during boot.

**Cons:**
- **Brittle:** Replacing a motherboard or NIC breaks the automation.
- **Security:** Exposes the entire cluster network topology within the ISO.

### Option B: Automated Virtual Media Injection (Ansible + Redfish)
| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium (Requires BMC integration) |
| Scalability | High (Managed via Inventory) |
| Hardware Dependency | Low (Generic OS image) |
| Maintenance | Low (Config lives in Git/Inventory) |

**Pros:**
- OS image remains generic and immutable.
- Configuration is injected at runtime based on real-time inventory.
- High security: secrets/configs are transient.

**Cons:**
- Depends on BMC (iLO/iDRAC) health and licensing.
- Requires network reachability to the Management Network (OOB).

### Option C: Zero-Touch Provisioning (IPv6 Link-Local / Elemental)
| Dimension | Assessment |
|-----------|------------|
| Complexity | High (Advanced network setup) |
| Scalability | **Maximum** |
| Hardware Dependency | None |
| Maintenance | Low (Post-registration config) |

**Pros:**
- Truly vendor-agnostic and hardware-independent.
- "Plug-and-play" behavior for field staff.

**Cons:**
- Requires IPv6 Link-Local and multicast-capable switches.
- High initial complexity in network engineering.

## Trade-off Analysis
The primary conflict is between **Simplicity (Option A)** and **Maintainability (Option B)**. Option A is tempting for small labs but fails in production due to the high cost of hardware lifecycles (RMA). Option B offers the best balance for professional environments by utilizing the existing BMC infrastructure to bridge the "static IP gap."

## Consequences
- **Easier:** Hardware replacement; new servers just need their MAC/IP updated in the Ansible inventory.
- **Harder:** Initial pipeline setup; requires building an Ansible-to-Redfish orchestration layer.
- **Revisit:** Evaluate the move to Option C (Zero-Touch) once the edge network infrastructure reaches sufficient IPv6 maturity.

## Action Items
1. [x] Define a standard `definition.yaml` in EIB for a **Generic OS Image** (no network profiles) → `network/definition-network.yaml`
2. [x] Develop an Ansible Playbook using the `community.general.redfish_command` module to generate and mount transient `combustion` ISOs → `ansible/playbooks/inject-network.yml`
3. [x] Validate the "RMA Workflow": ensure a technician can swap a server and re-run the pipeline without touching the EIB build process → update `nodes/<node>.env` and re-run `task generate-node -- <node>`

🦎 AIcko