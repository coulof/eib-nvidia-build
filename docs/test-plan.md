# Test Plan — Metal3 provisioning of the EIB+NVIDIA image

End-to-end validation of the architecture in [`ADR-001`](ADR-001-network-configuration-injection.md).
The harness is the SUSE-Edge [`metal3-demo`](https://github.com/suse-edge/metal3-demo)
repo, which packages everything we need (libvirt + sushy-tools + RKE2
management cluster + Metal3) into one Ansible-driven setup. We **swap out**
metal3-demo's image build and manifests for the artefacts in this repo.

The plan answers the three open questions left at the end of the consolidation
work — captured as Action Items 6, 7, 9 in ADR-001:

1. Is `nmc` on the deployed image's `$PATH`?
2. Does `spec.networkData` (manually set, not IPAM-templated) actually
   populate `network_data.json` on the deployed OS's `config-2` partition?
3. Does `02-configure-network.sh` run early enough that K3s comes up with the
   correct static IP and hostname on the first boot?

## Why metal3-demo and not raw sushy-tools

Sushy-tools is *one component* of metal3-demo (`roles/sushy-tools`).
metal3-demo also ships:

- `libvirt-setup` — host packages, m3-external bridge, libvirt domains
- `image-cache` — local HTTPS-served image cache reachable from the management cluster
- `management-cluster` — RKE2 + Rancher + MetalLB + cert-manager + Metal3 (Ironic + BMO) + CAPM3 + Rancher Turtles
- `kubernetes-tools` — kubectl, helm, etc.

Building this fabric from raw sushy-tools is ~1–2 days of yak-shaving;
metal3-demo brings it up in ~30 minutes on a supported host. The catch — its
downstream EIB image (`roles/edge-image-builder/templates/eib-config-metal3.yaml.j2`)
is bare, because the upstream design delivers per-node network config through
CAPI/RKE2 ignition, not from inside the image. We don't use CAPI; we bake K3s
in. So we run metal3-demo for the fabric and provide our own image + BMH CRs.

## Host requirements

| | minimum | recommended |
|---|---|---|
| RAM | 32 GB | 48 GB |
| Disk | 200 GB free | 300 GB free |
| CPU | 8 vCPU with VT-x/AMD-V | 12 vCPU |
| OS | openSUSE Tumbleweed (confirmed supported by metal3-demo) | same |
| KVM | `lsmod \| grep kvm_` shows the module | same |

Why so much: the management cluster VM (8 GB RAM / 4 vCPU) + 2 simulated nodes
(4 GB / 4 vCPU each, 30 GB disk each) + caches + our 6 GB raw image.

---

## Phase 0 — Clone and inspect metal3-demo

```bash
cd ~/src   # or wherever you keep checkouts
git clone https://github.com/suse-edge/metal3-demo.git
cd metal3-demo
```

Skim its [README](https://github.com/suse-edge/metal3-demo/blob/main/README.md).
Note the four entry-point scripts:

| Script | Role |
|---|---|
| `01_prepare_host.sh` | Install Ansible, packages, generate SSH key |
| `02_configure_host.sh` | libvirt + m3-external network + sushy-tools + image-cache |
| `03_build_images.sh` | EIB build of metal3-demo's own bare image — **skip** |
| `04_launch_mgmt_cluster.sh` | Boot the management cluster VM, fetch kubeconfig |

We run 01, 02, 04 in order. Skipping 03 means the management cluster won't
have a downstream image registered in its image cache — we'll seed our own.

## Phase 1 — Run metal3-demo to set up the fabric

### 1.1 Override key vars

`metal3-demo` reads `extra_vars.yml` at the repo root. Defaults are mostly
fine. The two overrides we want:

```yaml
# metal3-demo/extra_vars.override.yml
# Reduce to two simulated nodes — we don't need a control-plane/worker split
# because we're applying our own BareMetalHost CRs, not CAPI templates.
num_controlplane_hosts: 2
num_worker_hosts: 0
```

Run with the override:

```bash
EXTRA_VARS_FILE=$PWD/extra_vars.override.yml ./01_prepare_host.sh
EXTRA_VARS_FILE=$PWD/extra_vars.override.yml ./02_configure_host.sh
EXTRA_VARS_FILE=$PWD/extra_vars.override.yml ./04_launch_mgmt_cluster.sh
```

### 1.2 What you should see after Phase 1

- `virsh list --all` shows `mgmt-cluster`, `controlplane-host-1`,
  `controlplane-host-2`. The two host VMs are **off and empty** — sushy-tools
  drives them via Redfish virtual media.
- `curl http://192.168.125.1:8000/redfish/v1/Systems/` returns the two domain
  UUIDs.
- `kubectl --kubeconfig ~/.kube/metal3-demo get pods -A` shows `metal3-ironic`,
  `baremetal-operator-controller-manager`, etc. all `Running`.
- The image-cache server listens on `https://imagecache.local:8443/`. The
  `imagecache.local` hostname is wired into `/etc/hosts` of the management
  cluster VM by the `image-cache` role.

### 1.3 Capture inventory data

We need three things per simulated host:

```bash
# UUID for sushy-tools system ID
virsh domuuid controlplane-host-1
virsh domuuid controlplane-host-2

# MAC of the m3-external NIC (this becomes node_mac in our inventory)
virsh dumpxml controlplane-host-1 | grep -oE 'mac address=.[0-9a-f:]+' | head -1
virsh dumpxml controlplane-host-2 | grep -oE 'mac address=.[0-9a-f:]+' | head -1

# Interface name inside the booted OS — typically enp1s0 for virtio.
# Confirm by booting the VM once with any live ISO if uncertain.
```

Pick static IPs **outside** metal3-demo's DHCP range (`192.168.125.200–250`).
We'll use `192.168.125.50` and `.51`.

## Phase 2 — Build and host the EIB image

In this repo:

```bash
cd ~/go/src/github.com/coulof/eib-nvidia-build
git checkout metal3-test-with-sushy-tools

# (If not already done.) Decompress the SL Micro raw base.
unxz -k base-images/SL-Micro.x86_64-6.2-Base-GM.raw.xz

task build   # produces edge-nvidia-k3s-slmicro62.raw (~6 GB)

# Compute the checksum Ironic will verify
sha256sum edge-nvidia-k3s-slmicro62.raw | awk '{print $1}' > edge-nvidia-k3s-slmicro62.raw.sha256
```

Drop the image into metal3-demo's image cache so the management cluster can
pull it without a separate HTTP server:

```bash
sudo cp edge-nvidia-k3s-slmicro62.raw \
        /var/lib/libvirt/images/imagecache/
sudo cp edge-nvidia-k3s-slmicro62.raw.sha256 \
        /var/lib/libvirt/images/imagecache/
```

(Confirm the cache directory by inspecting `roles/image-cache` of metal3-demo
on the host you're using; the path may have changed across releases.)

The URL Ironic should use is then:

```
https://imagecache.local:8443/edge-nvidia-k3s-slmicro62.raw
```

## Phase 3 — Wire up our inventory and apply our BMH CRs

### 3.1 Edit `ansible/inventory.yml` for the test fabric

Drop in the values captured in 1.3 plus the image URL/checksum from 2:

```yaml
all:
  vars:
    metal3_namespace: metal3-system
    bmc_system_id: "<UUID-from-virsh-domuuid>"   # per-node, see hosts: below
    eib_image_http_url: https://imagecache.local:8443/edge-nvidia-k3s-slmicro62.raw
    eib_image_checksum: "<sha256-from-phase-2>"
    eib_image_checksum_type: sha256

  hosts:
    node01:
      bmc_ip: "192.168.125.1:8000"
      bmc_user: admin
      bmc_password: password   # from sushy-tools defaults; OK in a test fabric
      bmc_system_id: "<controlplane-host-1 UUID>"
      node_hostname: node01
      node_interface: enp1s0
      node_mac: "<controlplane-host-1 MAC>"
      node_ip: 192.168.125.50
      node_prefix: 24
      node_gateway: 192.168.125.1
      node_dns: 192.168.125.1

    node02:
      bmc_ip: "192.168.125.1:8000"
      bmc_user: admin
      bmc_password: password
      bmc_system_id: "<controlplane-host-2 UUID>"
      node_hostname: node02
      node_interface: enp1s0
      node_mac: "<controlplane-host-2 MAC>"
      node_ip: 192.168.125.51
      node_prefix: 24
      node_gateway: 192.168.125.1
      node_dns: 192.168.125.1
```

Two things worth flagging:

- `bmc_system_id` overrides the all-hosts default per host. This is the
  libvirt domain UUID that sushy-tools uses as its Redfish System ID.
- `bmc_password` is plaintext for the test only. In production, keep it in
  `secrets/bmc-<node>` and use the lookup pattern from before.

The `redfish-virtualmedia://...` URL in `metal3/baremetalhost.j2` already
templates correctly: `redfish-virtualmedia://192.168.125.1:8000/redfish/v1/Systems/<uuid>`.

### 3.2 Apply

```bash
export KUBECONFIG=~/.kube/metal3-demo   # path that 04_launch_mgmt_cluster.sh wrote
ansible-galaxy collection install -r ansible/requirements.yml
task register-nodes
```

You should see three resources per node land in the management cluster:

```bash
kubectl -n metal3-system get secret,baremetalhost
# node01-bmc-credentials   Opaque   2
# node01-networkdata       Opaque   1
# node02-bmc-credentials   Opaque   2
# node02-networkdata       Opaque   1
# baremetalhost.metal3.io/node01   ...   registering
# baremetalhost.metal3.io/node02   ...   registering
```

### 3.3 Watch provisioning

```bash
kubectl -n metal3-system get baremetalhosts -w
```

Expected state machine: `registering → inspecting → preparing → provisioning → provisioned`.
Total time: 10–25 minutes per node depending on host I/O.

If a state stalls, check Ironic logs:

```bash
kubectl -n metal3-system logs -l app.kubernetes.io/name=ironic -c ironic --tail=200
kubectl -n metal3-system logs -l app.kubernetes.io/name=ironic -c ironic-inspector --tail=200
```

---

## Phase 4 — Verification (the actual test)

Once both nodes reach `provisioned`, SSH in (or `virsh console controlplane-host-1`)
to confirm each open question.

### 4a — Image got written, OS boots

```bash
# From the host
virsh console controlplane-host-1
# login: root / <encrypted password from definition.yaml.tmpl>
# or use the SSH key
ssh -i ~/.ssh/id_ed25519 root@192.168.125.50
```

✅ Pass: prompt appears at the static IP we configured. ❌ Fail: it boots
DHCP-assigned address (.200+) → the script never ran or `nmc apply` failed.

### 4b — `nmc` is on `$PATH` (Action Item 6)

```bash
ssh root@192.168.125.50 'which nmc; nmc --version'
```

✅ Pass: prints a path and version. ❌ Fail: `command not found`. Fix: add
`nm-configurator` (or whatever the SUSE package is named) to
`definition.yaml.tmpl` `packageList`, rebuild, repeat Phase 2 + Phase 3.3.

### 4c — `network_data.json` actually landed on `config-2` (Action Item 9)

This is the SUSE-docs ambiguity test. If it fails, we'll know `spec.networkData`
on a `BareMetalHost` is genuinely unsupported in SUSE Edge and we have to
deliver the nmstate via `userData` ignition instead.

```bash
ssh root@192.168.125.50 << 'EOF'
set -e
DEV=$(blkid --label config-2)
echo "config-2 device: $DEV"
mkdir -p /tmp/cd && mount -o ro "$DEV" /tmp/cd
ls -la /tmp/cd/openstack/latest/
echo "--- meta_data.json ---"
cat /tmp/cd/openstack/latest/meta_data.json
echo "--- network_data.json ---"
cat /tmp/cd/openstack/latest/network_data.json
umount /tmp/cd
EOF
```

✅ Pass: `network_data.json` exists and contains the nmstate we put in the
Secret. ❌ Fail (file missing or empty): fall-back path is to remove
`spec.networkData` from `metal3/baremetalhost.j2`, deliver the nmstate via
`spec.userData` (ignition `storage.files` writing
`/var/lib/network/network_data.json`), and update
`02-configure-network.sh` to read from that path.

### 4d — Script ran early enough (Action Item 9b)

```bash
ssh root@192.168.125.50 'journalctl -b --no-pager -u combustion'
ssh root@192.168.125.50 'journalctl -b --no-pager -u k3s | head -80'
ssh root@192.168.125.50 'ip -4 a show enp1s0; nmcli con show'
ssh root@192.168.125.50 'hostnamectl'
```

✅ Pass:
- combustion log shows `01-fix-growfs.sh` then `02-configure-network.sh`
  completing with no errors;
- `enp1s0` carries `192.168.125.50/24`;
- `hostnamectl` returns `node01`;
- `journalctl -u k3s` shows zero "no route to host" or DNS retries before
  the first successful API call.

❌ Fail with K3s retries: the script ran *after* K3s started. Fix candidates:
move the call earlier (e.g. into `combustion/script` ahead of the K3s install
script), or ensure `custom/scripts/` ordering puts `02-configure-network.sh`
before whatever script EIB injects for K3s. Inspect ordering with
`ls /run/initramfs/combustion/` on the booted node.

### 4e — Hostname plumbing (sanity check)

`hostnamectl` already covered this in 4d. Also confirm on the management cluster:

```bash
kubectl -n metal3-system get baremetalhost node01 -o jsonpath='{.status.hardware.hostname}'
```

Should return `node01`.

### 4f — RMA simulation (the architectural promise)

Verifies the whole point of this design — replacing hardware shouldn't require
an image rebuild.

```bash
# Destroy and recreate the libvirt domain with a new MAC, simulating an RMA
virsh destroy controlplane-host-1
virsh undefine controlplane-host-1 --remove-all-storage
# Recreate via metal3-demo's role — easiest is to rerun configure_host.yml with
# num_controlplane_hosts=2 (the role is idempotent and will recreate missing VMs)
( cd ~/src/metal3-demo && \
  EXTRA_VARS_FILE=$PWD/extra_vars.override.yml ./02_configure_host.sh )

# Capture the new MAC
NEW_MAC=$(virsh dumpxml controlplane-host-1 | grep -oE 'mac address=.[0-9a-f:]+' | head -1 | cut -d\' -f2)
NEW_UUID=$(virsh domuuid controlplane-host-1)

# Update inventory.yml node01 with NEW_MAC + NEW_UUID, then:
kubectl -n metal3-system delete baremetalhost node01
task register-nodes -- node01

kubectl -n metal3-system get baremetalhost node01 -w
ssh root@192.168.125.50 hostnamectl   # same hostname → same EIB image, new HW
```

✅ Pass: node reaches `provisioned`, same `node01` hostname, same static IP,
no image rebuild needed.

---

## Cleanup

```bash
# Tear down our BMHs (leaves metal3-demo fabric intact for re-runs)
kubectl -n metal3-system delete baremetalhost --all
kubectl -n metal3-system delete secret -l 'app.kubernetes.io/managed-by=ansible'  # if labels were set; otherwise delete by name

# Tear down everything (libvirt VMs, networks, sushy-tools)
( cd ~/src/metal3-demo && make clean )   # if exposed; otherwise `virsh` by hand
```

---

## Open questions to resolve while running this

These are the things we can't decide on paper — file as comments on the PR
that introduces this doc, or update the doc inline as we learn:

1. **Where exactly is metal3-demo's image cache directory** on Tumbleweed for
   the version you check out? The path in 2.4 above is the typical default;
   confirm by looking at `roles/image-cache/defaults/main.yml` in the cloned
   repo or by inspecting `/etc/nginx/...` on the host after step 1.
2. **What does sushy-tools call the system ID** — domain UUID or domain name?
   The metal3-demo defaults suggest UUID; verify by `curl
   http://192.168.125.1:8000/redfish/v1/Systems/`.
3. **Does the management cluster have outbound access** to the SUSE registry
   (`registry.suse.com`) to pull the EIB-baked NVIDIA stack at first boot?
   The image is pre-baked but `nvidia-device-plugin` Helm install at K3s
   bootstrap pulls images from `registry.suse.com` and `nvcr.io`. If the m3-
   network is air-gapped, that stage will fail — a known limitation, not a
   bug in this repo.
4. **Does the lab have a real GPU?** No — these are KVM VMs. The NVIDIA
   driver kmod will load against no hardware and the device plugin will
   report 0 GPUs. That is fine for this test — we are validating provisioning
   and network config, not the GPU stack. GPU validation needs real iron.

---

## What success looks like

A run-through of Phase 4 with all six checks ✅ on **two** nodes, including
the RMA simulation. At that point Action Items 6, 7, 9 in ADR-001 close, and
the architecture is verified end-to-end against a real Ironic + Redfish stack.
