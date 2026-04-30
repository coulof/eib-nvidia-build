# ADR-002: Adopt Metal3 for Bare-Metal Provisioning

**Status:** Proposed
**Date:** 2026-04-30
**Supersedes:** ADR-001 Option B (Ansible+Redfish per-node combustion ISO injection)
**References:**
- https://documentation.suse.com/suse-edge/3.5/html/edge/quickstart-metal3.html

---

## Context

ADR-001 Option B (implemented) uses Ansible+Redfish to: generate a per-node combustion ISO via EIB,
mount it as virtual media via BMC, set one-time CD boot, and reboot the node. This works for a
single cluster but has structural limitations at fleet scale:

- **Imperative** — playbook runs once; no reconciliation if a node drifts or a provisioning step fails mid-way
- **No inventory of hardware state** — Ansible has no persistent model of which nodes are provisioned, inspected, or failed
- **Manual ISO lifecycle** — ISOs must be served over HTTP, per-node workdirs must be managed, HTTP server must be running
- **Does not integrate with Cluster API** — adding nodes to an existing cluster or scaling a fleet requires a separate workflow

The target deployment is **multi-site / fleet at scale**. SUSE Edge ships Metal3 as its native
bare-metal provisioning stack. Metal3 (via Ironic) also uses Redfish under the hood — the hardware
interface is the same — but wraps it in a Kubernetes-native declarative API with full lifecycle
state management.

## Key Insight: Metal3 Complements EIB, It Does Not Replace It

EIB's role (build a signed, air-gapped SL Micro image) is unchanged. Metal3 takes over the
"get the image onto hardware" step currently handled by the Ansible playbook.

Per-node network config (static IP, hostname) moves from combustion ISOs injected as Redfish
virtual media to **BareMetalHost `userData`** (a Kubernetes Secret holding an ignition config),
which Ironic passes to the OS at provisioning time. The `nmconnection.j2` and
`combustion-script.j2` templates remain relevant — their content rides through Metal3's
provisioning pipeline instead of a separate Redfish virtual media ISO.

## Options Considered

### Option A: Keep Ansible+Redfish (current ADR-001 Option B)

| Dimension | Assessment |
|---|---|
| Complexity | Low — already implemented |
| Scalability | Medium — manual ISO lifecycle, no reconciliation |
| Hardware state | None — Ansible has no memory of node states |
| GitOps fit | Poor — imperative playbooks |
| SUSE alignment | Partial — uses Redfish but not the SUSE-recommended stack |

**Pros:** Working today, minimal infrastructure overhead.
**Cons:** Does not scale to fleet; no self-healing; ISOs must be managed and served manually; no Cluster API integration.

### Option B: Adopt Metal3 (recommended)

| Dimension | Assessment |
|---|---|
| Complexity | High — requires management cluster + Ironic + BMO + CAPM3 + MetalLB |
| Scalability | High — declarative, self-healing, Cluster API native |
| Hardware state | Full lifecycle (registering → inspecting → available → provisioning → provisioned) |
| GitOps fit | Excellent — BareMetalHost CRDs in git, Fleet-compatible |
| SUSE alignment | Native — the documented production path |

**Pros:** Declarative state machine per node; GitOps-ready; Cluster API enables automated scale-out; no manual ISO serving.
**Cons:** Requires a management cluster. IPAM controller not yet supported in SUSE Edge — static IPs
still require per-node userData injection.

## Trade-off Analysis

The core trade-off is **operational complexity now vs operational simplicity at scale**.

Metal3's state machine (registering → inspecting → available → provisioning → provisioned →
deprovisioning) gives operators a single control plane to understand the state of every bare-metal
node across all sites. Adding a node to the fleet becomes: create a `BareMetalHost` CR with BMC
credentials; Metal3 handles the rest.

The Ansible approach's lack of state management means every re-provisioning event, hardware
replacement (RMA), or failed boot requires manual diagnosis and re-running playbooks with no audit
trail of node states.

## Decision

Adopt Metal3 as the provisioning layer. Migrate per-node network config from combustion ISOs
to BareMetalHost `userData` Secrets (ignition format). Keep EIB unchanged for image building.

## Consequences

- **Easier:** Hardware replacement; visibility into node lifecycle state; GitOps via Fleet
- **Harder:** Initial setup requires a management cluster before any node can be provisioned
- **Unchanged:** EIB image build workflow (`task build`), NVIDIA stack, Jinja2 template content
- **Superseded:** `ansible/playbooks/generate-and-inject.yml`, `task deploy`, combustion ISO generation

## Required Infrastructure (Management Cluster)

| Component | Purpose |
|---|---|
| RKE2 cluster (single node OK) | Management cluster host |
| Rancher + Rancher Turtles | Lifecycle UI + fleet management |
| MetalLB | Reserved IPs for Ironic/CAPM3 endpoints |
| Ironic (via Metal3 Helm chart) | Bare-metal provisioning engine |
| Baremetal Operator | Controller for BareMetalHost CRDs |
| CAPM3 | Cluster API provider for Metal3 |

## Migration Path

### Phase 1 — Build management cluster (prerequisite, out of scope for this repo)
1. Deploy a single-node RKE2 cluster on a management host
2. Install Rancher + Rancher Turtles
3. Deploy MetalLB, Metal3 chart (Ironic + BMO), CAPM3

### Phase 2 — Register nodes (this repo)
```bash
task register-nodes           # register all nodes
task register-nodes -- node01 # register a single node
```

Internally: renders `metal3/baremetalhost.j2` and builds an ignition userData Secret per node,
then applies them to the management cluster via `kubectl`.

### Phase 3 — Monitor provisioning
```bash
kubectl get baremetalhosts -A
kubectl get baremetalhost <node> -o jsonpath='{.status.provisioning.state}'
```

### Phase 4 — Deprecate Ansible injection
Once Metal3 is validated on the first site, retire `generate-and-inject.yml` and `task deploy`.

## Action Items

1. [x] Create `metal3/baremetalhost.j2` — BareMetalHost CR template
2. [x] Create `ansible/playbooks/register-nodes.yml` — renders and applies Metal3 CRDs
3. [x] Add `task register-nodes` to Taskfile
4. [ ] Build management cluster (Phase 1)
5. [ ] Add `eib_image_http_url` and `eib_image_checksum` to inventory once image is hosted
6. [ ] Validate ignition userData format against SUSE Edge 3.5 Metal3 docs
7. [ ] Deprecate `generate-and-inject.yml` after first successful Metal3 provisioning
