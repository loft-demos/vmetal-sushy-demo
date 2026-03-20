# Local Setup Instructions (MINISFORUM X1 Pro 370)

Machine-specific cheat sheet for a full tear-down and re-run. For full context see README.md.

## Kernel requirement

The MINISFORUM X1 Pro 370 uses the AMD Ryzen AI 9 HX370 (Strix Point). The Ubuntu 24.04 GA kernel (`6.8`) does not include the driver for its built-in 5G Ethernet NICs (`r8169` variant on this chipset). You need the **HWE kernel** to get a working network interface:

```bash
sudo apt install linux-generic-hwe-24.04
sudo reboot
```

After reboot, verify the management NIC is up:

```bash
ip -brief link show enp197s0   # should show UP
```

Without the HWE kernel, `enp197s0` will not appear and the machine will have no network after Ubuntu install.

---

## Your machine facts

| Thing | Value |
| --- | --- |
| Management NIC | `enp197s0` |
| LAN IP | `192.168.50.61` |
| Gateway IP (free) | `192.168.50.200` |
| Domain | `vdemo.local` |
| Platform UI | `http://vcp.vdemo.local` |
| Provisioning bridge | `br-provision` @ `172.22.0.1/24` |
| Sushy Tools | `http://172.22.0.1:8000` |
| OS Image server | `http://172.22.0.1:9000` |

---

## Teardown (before a re-run)

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml

# 1. Delete the vCluster and NodeClaims (releases BareMetalHosts)
kubectl delete virtualclusterinstance vmetal-demo -n p-default

# 2. Delete BareMetalHosts
kubectl delete baremetalhost --all -n metal3-system

# 3. Delete the NodeProvider (undeploys Metal3, Ironic, DHCP, Multus)
kubectl delete nodeprovider metal3-provider

# 4. Tear down local infra (sushy-tools, VMs, bridge)
bash scripts/reset-demo.sh
```

> **Note:** You do NOT need to reinstall vCluster Standalone or vCluster Platform.
> Resume from Step 3 after teardown.

---

## Step 0 — Sync the repo from your Mac

From your Mac (re-run any time you make changes):

```bash
rsync -av --exclude='.git' \
  "/Users/kmadel/Library/Mobile Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/" \
  kmadel@192.168.50.61:~/loft-demos/vmetal-sushy-demo/
```

---

## Step 1 — Fill in `.env`

On the MINISFORUM (already done — your values are below):

```bash
cd ~/loft-demos/vmetal-sushy-demo
cp configs/.env.example .env
```

Set these values in `.env`:

```bash
LAN_INTERFACE=enp197s0
LAN_IP=192.168.50.61
VDEMO_DOMAIN=vdemo.local
GATEWAY_IP=192.168.50.200
METALLB_IP_RANGE=192.168.50.200-192.168.50.200
VCP_LOFT_HOST=vcp.vdemo.local
VCP_LICENSE_TOKEN=<your Scale tier token>
VM_IMAGE_DIR=/var/lib/libvirt/images
```

---

## Step 2 — Bootstrap the host

```bash
bash scripts/bootstrap-host.sh
```

Installs qemu-kvm, libvirt, virtinst, ovmf, python3-venv, Helm, CNI plugins, and creates OVMF symlinks. Safe to re-run.

**After it finishes: log out and back in** (or `newgrp libvirt`) so group changes take effect.

Verify:

```bash
kvm-ok
sudo virsh list --all
```

---

## Step 3 — Create the provisioning bridge and VMs

```bash
bash scripts/create-bridges.sh
bash scripts/create-vms.sh
```

`create-bridges.sh` creates `br-provision` at `172.22.0.1/24` with STP disabled and sets up NAT masquerade via `enp197s0` so provisioning VMs can reach the internet.

Verify:

```bash
ip addr show br-provision        # should show 172.22.0.1/24
sudo virsh list --all            # 5 VMs, all shut off
cat configs/vm-inventory.txt     # UUID, MAC, profile for each VM
```

---

## Step 4 — Start Sushy Tools

```bash
bash scripts/install-sushy-service.sh
```

Installs and starts the sushy-tools systemd service (Redfish emulator on port 8000).

Verify — all 5 VM UUIDs should appear:

```bash
curl http://172.22.0.1:8000/redfish/v1/Systems/ | jq .
```

---

## Step 5 — DNS

On the MINISFORUM:

```bash
bash scripts/install-dnsmasq.sh
```

On your Mac:

```bash
bash hack/setup-mac-dns.sh
```

Verify from your Mac:

```bash
dig +short vcp.vdemo.local   # should return 192.168.50.200
```

---

## Step 6 — Install vCluster Standalone + Platform

> Skip this step if vCluster Standalone and Platform are already installed and running.

```bash
bash scripts/install-vcluster.sh
```

Takes several minutes. Watch the Platform pods:

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml
kubectl -n vcluster-platform get pods -w
```

Once all pods are `Running`, open **http://vcp.vdemo.local** from your Mac and log in.

---

## Step 7 — Apply the NodeProvider

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml
kubectl apply -f manifests/platform/node-provider.yaml
```

This deploys Metal3, Ironic, DHCP proxy, and Multus into `metal3-system`. Takes a few minutes.

Watch it deploy:

```bash
kubectl get nodeprovider metal3-provider -w
# Wait for: Ready
```

Verify all components are running:

```bash
kubectl get pods -n metal3-system
# Expect: ironic, baremetal-operator, dhcp-proxy, multus pods
```

---

## Step 8 — Register the fake servers

```bash
bash hack/generate-bmh.sh | kubectl apply -f -
```

Creates one `BareMetalHost` + BMC credentials `Secret` per VM. Watch them progress:

```bash
kubectl -n metal3-system get baremetalhost -w
# States: registering → inspecting → available
# All 5 should reach "available" (takes ~5 minutes)
```

---

## Step 9 — Cache the OS image

The IPA ramdisk has no internet access — serve the image locally for ~40s provisioning.

```bash
bash scripts/cache-os-image.sh
```

Downloads Ubuntu 24.04 minimal to `/srv/os-images/` and starts the `os-image-server` systemd service on `http://172.22.0.1:9000/`.

Verify:

```bash
curl -I http://172.22.0.1:9000/ubuntu-24.04-minimal-cloudimg-amd64.img
# Expect: HTTP/1.0 200 OK
```

---

## Step 10 — Apply platform manifests and create the vCluster

```bash
# OSImage (tells vMetal where to find Ubuntu)
kubectl apply -f manifests/platform/os-image.yaml

# VirtualClusterTemplate (parameterized template for vMetal bare metal vClusters)
kubectl apply -f manifests/platform/vmetal-template.yaml

# VirtualClusterInstance (creates vmetal-demo, claims one small BareMetalHost)
kubectl apply -f manifests/platform/vcluster-vmetal.yaml
```

Watch the provisioning pipeline:

```bash
# NodeClaim transitions: Pending → Provisioned → Joined
kubectl get nodeclaims -A -w

# BareMetalHost transitions: available → provisioning → provisioned
kubectl -n metal3-system get baremetalhost -w
```

Once the node is `Joined`, open the vmetal-demo vCluster in the Platform UI and check Nodes + Pods.

---

## Upgrade demo

To demonstrate a Kubernetes control plane upgrade, edit the `kubernetesVersion` parameter and re-apply:

```bash
# Edit vcluster-vmetal.yaml: kubernetesVersion: v1.35.0
kubectl apply -f manifests/platform/vcluster-vmetal.yaml
```

vCluster Platform re-renders the Helm release and performs a rolling control plane upgrade. Watch in the Platform UI under vmetal-demo → Status.

---

## Useful commands

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml

# Sushy / Redfish
sudo systemctl status sushy-tools
curl http://172.22.0.1:8000/redfish/v1/Systems/ | jq .

# OS image server
sudo systemctl status os-image-server
curl -I http://172.22.0.1:9000/ubuntu-24.04-minimal-cloudimg-amd64.img

# VMs
sudo virsh list --all
sudo virsh domiflist vmetal-small-1

# BareMetalHosts
kubectl -n metal3-system get baremetalhost
kubectl -n metal3-system describe baremetalhost vmetal-small-1

# NodeClaims
kubectl get nodeclaims -A

# Ironic logs (image write progress)
kubectl logs -n metal3-system -l app=ironic -c ironic --tail=50 -f

# dnsmasq
sudo systemctl status dnsmasq
sudo journalctl -u dnsmasq -n 20

# vCluster control plane
kubectl get nodes
kubectl -n vcluster-platform get pods

# NAT rules (provisioning VMs → internet)
sudo iptables -t nat -L POSTROUTING -n | grep 172.22
sudo iptables -L FORWARD --line-numbers | head -20
```
