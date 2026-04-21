# Design Notes

## Why vCluster Standalone (no separate K3s / kind / k3d)

vCluster can run as a standalone binary process on the host machine without a pre-existing Kubernetes cluster. This eliminates one layer of infrastructure from the demo: there is no "host cluster" to install separately. The vCluster Standalone binary is the cluster.

This keeps the setup to a single machine with a single install step for the control plane, which matches the demo's goal of being as simple to reproduce as possible.

---

## Why Sushy Tools over VirtualBMC

OpenStack VirtualBMC emulates IPMI, the older out-of-band management protocol. Metal3 and Ironic support IPMI, but they have moved toward Redfish as the preferred protocol for newer hardware. Sushy Tools emulates Redfish, which is what this demo uses.

Naming caveat: some KubeVirt-based demos use a different component named `virtbmc` (for example, KubeVirtBMC) that can expose Redfish. That is not the same project as OpenStack VirtualBMC. In this repository, when we compare emulator choices, "VirtualBMC" means the OpenStack IPMI tool.

Practical reasons to prefer Sushy Tools for this demo:
- Redfish is what Metal3/Ironic defaults to and is better tested in recent releases.
- `disableCertificateVerification: true` on BareMetalHost handles the lack of TLS without needing IPMI-specific workarounds.
- Sushy Tools requires only a Python venv + pip install — no additional daemon or port mapping needed beyond the libvirt socket.

---

## Why plain HTTP for Sushy Tools (and `redfish+http://` not `redfish://`)

Generating and managing TLS certificates adds complexity without benefit in a single-machine local demo. All traffic between Ironic and Sushy Tools stays on the local host (or within the cluster's pod network, which routes back to the host bridge IP). There is no external exposure.

The tradeoff is captured in the BareMetalHost manifest as `disableCertificateVerification: true`, which tells Ironic not to validate the (non-existent) certificate.

**Critical**: The BMC address scheme in BareMetalHost must be `redfish+http://`, not `redfish://`. The bare `redfish://` scheme forces HTTPS and causes an immediate SSL handshake failure against sushy-tools' plain HTTP endpoint. `hack/generate-bmh.sh` uses `redfish+http://` automatically.

If you want TLS for a more realistic demo, generate a self-signed cert and set `SUSHY_EMULATOR_SSL_CERT` / `SUSHY_EMULATOR_SSL_KEY` in `configs/sushy-tools.conf`, and remove `disableCertificateVerification` from the BareMetalHost resources.

---

## Why the OS image is served locally

The IPA (Ironic Python Agent) ramdisk that Ironic boots on each bare metal VM is isolated to the provisioning bridge (`172.22.0.0/24`). It has no DNS resolver and no route to the internet — by design. If the `OSImage` URL points at an external host (e.g. `cloud-images.ubuntu.com`), the IPA agent fails immediately with:

```
NameResolutionError: Failed to resolve 'cloud-images.ubuntu.com' ([Errno -2] Name or service not known)
```

`scripts/cache-os-image.sh` solves this by:
1. Downloading the Ubuntu 24.04 minimal image to `/srv/os-images/` on the host
2. Starting the `os-image-server` systemd service — a Python HTTP server on `172.22.0.1:9000`

The `OSImage` resource then points at `http://172.22.0.1:9000/ubuntu-24.04-minimal-cloudimg-amd64.img` — reachable by the IPA ramdisk over the bridge with no DNS required.

Side benefit: provisioning time drops from 8+ minutes (downloading over the internet) to ~40 seconds (local disk read over a virtual bridge).

---

## NAT masquerade — why provisioned nodes need internet access and how it works

The IPA ramdisk itself does not need internet access (it gets the OS image locally), but once Ubuntu is provisioned and `kubelet` starts, the node needs to:
- Resolve hostnames (`ghcr.io`, `registry.k8s.io`, `docker.io`)
- Pull container images for kube-proxy, CNI, and workload pods

The provisioning bridge is not routed to the internet by default. `create-bridges.sh` adds:
1. `net.ipv4.ip_forward=1` — enables the host to forward packets between interfaces
2. iptables FORWARD rules — allows traffic between `br-provision` and the LAN interface in both directions
3. iptables MASQUERADE — rewrites the source IP of packets leaving the provisioning subnet so the router sees the host's LAN IP

**`LAN_INTERFACE` must be set correctly.** It must match the interface shown by `ip route show default`. On the MINISFORUM X1 Pro 370 this is `enp197s0`. Using the wrong interface (e.g. `enp1s0`) means the MASQUERADE rule targets an interface that isn't carrying traffic, and provisioned VMs get no internet access — causing `ImagePullBackOff` on every pod.

Rules are saved via `netfilter-persistent` and survive reboots.

---

## rootDeviceHints — KVM virtio disks are `/dev/vda`, not `/dev/sda`

KVM/QEMU VMs use the virtio block driver. The disk appears as `/dev/vda` inside the guest, not `/dev/sda`. Metal3 defaults to looking for `/dev/sda` when no `rootDeviceHints` are set, which causes provisioning to fail with:

```
No suitable device found for hints {'name': '== /dev/sda'}
```

`hack/generate-bmh.sh` sets `rootDeviceHints.deviceName: /dev/vda` on every BareMetalHost automatically. On real hardware with SATA/SAS disks, this hint would typically be `/dev/sda` or omitted.

---

## VirtualClusterTemplate variants and the upgrade demo path

The demo now ships with two `VirtualClusterTemplate` variants:

### Dynamic template

`manifests/platform/vmetal-template.yaml` models an on-demand pool with Auto Nodes dynamic scaling. It exposes these parameters:

| Parameter | Purpose | Default | Options |
|---|---|---|---|
| `kubernetesVersion` | K8s control plane version | `v1.34.7` | `v1.33.11`, `v1.34.7`, `v1.35.4` |
| `nodeType` | BareMetalHost class to target | `small-node` | `small-node`, `medium-node`, `large-node` |
| `cpuLimit` | Maximum CPUs that can be provisioned by this node pool | `5` | `2`, `3`, `5`, `6`, `10` |

### Static template

`manifests/platform/vmetal-static-template.yaml` models fixed-size pools that are closer to the reserved-capacity pattern we usually see in AI clouds. It exposes one quantity parameter per node type:

| Parameter           | Purpose | Default | Options |
|---------------------|---|---|---|
| `kubernetesVersion` | K8s control plane version | `v1.34.7` | `v1.33.11`, `v1.34.7`, `v1.35.4` |
| `smallNodeCount`    | Number of `small-node` workers to keep present | `1` | `0`, `1`, `2`, `3` |
| `mediumNodeCount`   | Number of `medium-node` workers to keep present | `0` | `0`, `1` |
| `largeNodeCount`    | Number of `large-node` workers to keep present | `1` | `0`, `1`, `2` |

Both templates render into a vCluster Helm release using `controlPlane.distro.k8s.version` to set the K8s version. This enables a live upgrade demo:

1. Create the vCluster at `v1.34.7` (one small bare metal node)
2. Edit `manifests/platform/vcluster-vmetal.yaml`: change `kubernetesVersion` to `v1.35.4`
3. `kubectl apply -f manifests/platform/vcluster-vmetal.yaml`
4. vCluster Platform re-renders the Helm release and performs a rolling control plane upgrade
5. Watch the upgrade in the Platform UI under vmetal-demo → Status

The same upgrade flow works for `manifests/platform/vcluster-vmetal-static.yaml`; only the worker-pool shape differs.

This shows that the Kubernetes version is just a parameter. The vMetal bare metal nodes continue running through a control plane upgrade without reprovisioning the workers solely because the control plane version changes.

---

## cert-manager as a Metal3 dependency

Metal3 uses cert-manager to issue certificates for internal webhook and admission controller endpoints. The `NodeProvider` will fail to deploy Metal3 if cert-manager CRDs are not present in the cluster.

`configs/vcluster.yaml` includes cert-manager in the experimental deploy section, so `install-vcluster.sh` installs it automatically. If you install vCluster Platform by other means, install cert-manager first:

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.16.2 \
  --set crds.enabled=true
```

---

## VM sizing rationale (MINISFORUM X1 Pro 370 — 12 cores / 24 threads / 64 GB RAM)

The AMD Ryzen AI 9 HX370 has 12 cores (4 Zen 5 performance + 8 Zen 5c efficiency) and 24 hardware threads. KVM exposes these as 24 vCPUs available to guests.

Rough resource allocation for the default configuration:

| Component | Estimated vCPU | Estimated RAM |
| --- | --- | --- |
| Ubuntu host OS | 1–2 | ~2 GB |
| vCluster Standalone | 1–2 | ~2–4 GB |
| Metal3 / Ironic / DHCP (platform-managed) | 2–4 | ~4–6 GB |
| 3x small VMs (2 vCPU each) | 6 | 12 GB |
| 2x large VMs (4 vCPU each) | 8 | 16 GB |
| **Total** | **~18–22 vCPU** | **~36–40 GB** |

This leaves 2–6 vCPUs and 24+ GB of RAM as headroom, which is comfortable for demo stability. Swap should be disabled or minimal on a KVM host to avoid latency spikes.

Note: vCPU overcommit (assigning more vCPUs than physical threads) is fine for idle VMs, but keeping total vCPU allocation under the physical thread count avoids scheduler contention during provisioning when all VMs are active simultaneously.

### Small VMs (vmetal-small-N)
- 2 vCPU / 4 GB RAM / 40 GB disk
- Represent lightweight worker nodes
- Label: `vmetal-size: small`
- Suitable for showing the basic bare-metal provisioning lifecycle

### Large VMs (vmetal-large-N)
- 4 vCPU / 8 GB RAM / 80 GB disk
- Represent compute-heavy or GPU-class nodes
- Label: `vmetal-size: large`
- Suitable for demonstrating node type selection and differentiated provisioning

Both sizes are configured in `.env` and can be adjusted by editing `SMALL_VM_*` and `LARGE_VM_*` variables.

---

## NVMe storage strategy

The MINISFORUM X1 Pro 370 has a 1 TB SSD (OS) plus two 2 TB NVMe SSDs. VM disk images perform better on the NVMe SSDs because:
- The OS SSD is also serving system I/O, vCluster state, and container images.
- VM qcow2 files are write-heavy during provisioning (OS install by Ironic writes the entire image).

To use the NVMe SSDs for VM images:
1. Mount one NVMe SSD (e.g., `/dev/nvme1n1`) to a path like `/mnt/nvme0`.
2. Set `VM_IMAGE_DIR=/mnt/nvme0/libvirt/images` in `.env`.
3. Run `scripts/create-vms.sh` — it will create the directory and place images there.

You can also create a named libvirt storage pool pointing at the NVMe mount:
```bash
sudo virsh pool-define-as nvme0 dir --target /mnt/nvme0/libvirt/images
sudo virsh pool-build nvme0
sudo virsh pool-start nvme0
sudo virsh pool-autostart nvme0
```

This allows the libvirt UI tools to see the pool, but is optional — `create-vms.sh` uses `--disk path=...` directly and does not require a named pool.

---

## AMD Ryzen AI 9 HX370 and KVM

The AMD Ryzen AI 9 HX370 supports AMD-V (hardware virtualization). After enabling it in BIOS/UEFI, KVM should be available without additional configuration on Ubuntu 24.04.

Verify with:
```bash
kvm-ok
# Expected: INFO: /dev/kvm exists
#           KVM acceleration can be used

# Also check the KVM module
lsmod | grep kvm
# Expected: kvm_amd and kvm listed
```

If `kvm-ok` reports a problem, check:
- BIOS/UEFI → Advanced → CPU Configuration → SVM Mode (or AMD-V) is Enabled
- Secure Boot is not interfering with KVM module loading

---

## Metal3 and Ironic as platform-managed components

In this demo, Metal3, Ironic, DHCP, and Multus are deployed and managed by vMetal through the `NodeProvider` resource. You do not install them manually. The demo narrative should reflect this:

> "vCluster Platform's vMetal feature deploys the bare-metal stack. You configure a NodeProvider, and the platform handles Ironic, DHCP, and the Metal3 operator."

This is the core product story. The local VM infrastructure (libvirt, Sushy Tools) is just the stand-in for real hardware — it is not the headline feature.
