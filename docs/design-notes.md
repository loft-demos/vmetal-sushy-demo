# Design Notes

## Why vCluster Standalone (no separate K3s / kind / k3d)

vCluster can run as a standalone binary process on the host machine without a pre-existing Kubernetes cluster. This eliminates one layer of infrastructure from the demo: there is no "host cluster" to install separately. The vCluster Standalone binary is the cluster.

This keeps the setup to a single machine with a single install step for the control plane, which matches the demo's goal of being as simple to reproduce as possible.

---

## Why Sushy Tools over VirtualBMC

VirtualBMC emulates IPMI, the older out-of-band management protocol. Metal3 and Ironic support IPMI, but they have moved toward Redfish as the preferred protocol for newer hardware. Sushy Tools emulates Redfish, which is what this demo uses.

Practical reasons to prefer Sushy Tools for this demo:
- Redfish is what Metal3/Ironic defaults to and is better tested in recent releases.
- `disableCertificateVerification: true` on BareMetalHost handles the lack of TLS without needing IPMI-specific workarounds.
- Sushy Tools requires only a Python venv + pip install — no additional daemon or port mapping needed beyond the libvirt socket.

---

## Why plain HTTP for Sushy Tools

Generating and managing TLS certificates adds complexity without benefit in a single-machine local demo. All traffic between Ironic and Sushy Tools stays on the local host (or within the cluster's pod network, which routes back to the host bridge IP). There is no external exposure.

The tradeoff is captured in the BareMetalHost manifest as `disableCertificateVerification: true`, which tells Ironic not to validate the (non-existent) certificate. This is the correct knob for this use case.

If you want TLS for a more realistic demo, generate a self-signed cert and set `SUSHY_EMULATOR_SSL_CERT` / `SUSHY_EMULATOR_SSL_KEY` in `configs/sushy-tools.conf`, and remove `disableCertificateVerification` from the BareMetalHost resources.

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
