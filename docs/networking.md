# Networking Design

## Overview

This demo uses two network segments on the Ubuntu host:

1. **Management NIC** (`enp197s0` on the MINISFORUM, variable elsewhere) — carries LAN traffic: SSH, vCluster Platform UI, internet access for the host.
2. **Provisioning bridge** (`br-provision`, `172.22.0.0/24`) — carries PXE, DHCP, Redfish, and post-provisioning node traffic. All libvirt VMs attach to this bridge.

```
Host machine (Ubuntu 24.04)
│
├── enp197s0  (management NIC — SSH, UI)
│     LAN IP: 192.168.50.61 (DHCP from router)
│     NAT masquerade: forwards provisioning subnet → internet
│
└── br-provision  (Linux bridge — provisioning network)
      IP: 172.22.0.1/24
      │
      ├── vmetal-small-1  (VM, 52:54:00:aa:00:00, static 172.22.0.11)
      ├── vmetal-small-2  (VM, 52:54:00:aa:00:01, static 172.22.0.12)
      ├── vmetal-small-3  (VM, 52:54:00:aa:00:02, static 172.22.0.13)
      ├── vmetal-large-1  (VM, 52:54:00:bb:00:00, static 172.22.0.14)
      └── vmetal-large-2  (VM, 52:54:00:bb:00:01, static 172.22.0.15)
```

> **Note:** The management NIC name varies by hardware. Check yours with `ip route show default` — the interface listed there is the one to use for `LAN_INTERFACE` in `.env`.

---

## Why a plain Linux bridge instead of a libvirt virtual network

libvirt's built-in virtual networks create their own dnsmasq DHCP server. For Metal3/Ironic, **Ironic must own DHCP** on the provisioning network — it uses DHCP to track which machine is PXE-booting and to drive the inspection and provisioning state machine. Running two DHCP servers on the same segment causes random provisioning failures.

A plain Linux bridge avoids this: no DHCP is started by default, and the vCP DHCP proxy attaches to the bridge through a Multus `NetworkAttachmentDefinition`.

---

## Why STP must be disabled

Spanning Tree Protocol (STP) introduces a forwarding delay (typically 30 seconds) when a bridge port first comes up. During this delay DHCP and PXE traffic is dropped, causing PXE boot to fail entirely.

`create-bridges.sh` disables STP via `ip link set br-provision type bridge stp_state 0` and persists this in a systemd-networkd drop-in.

Verify:

```bash
cat /sys/class/net/br-provision/bridge/stp_state   # must be 0
```

---

## IP address allocation

| Address | Role |
|---|---|
| `172.22.0.1` | Host bridge IP; Sushy Tools Redfish endpoint; OS image server |
| `172.22.0.2` | DHCP VIP for the vCP DHCP proxy (set in `node-provider.yaml`) |
| `172.22.0.11–15` | Static IPs assigned to VMs during inspection/provisioning |

IPs are assigned statically by the vCP DHCP proxy using `metal3.vcluster.com/ip-address` annotations on each BareMetalHost. `hack/generate-bmh.sh` assigns these sequentially starting from `VM_IP_START` (default `172.22.0.11`).

---

## NAT masquerade — giving provisioned nodes internet access

The provisioning bridge is not fully isolated. Provisioned bare metal nodes need internet access after booting Ubuntu to:

- Pull container images from `ghcr.io`, `registry.k8s.io`, `docker.io`
- Reach DNS to resolve image registry hostnames

The IPA ramdisk (used during Ironic inspection and image writing) does **not** need internet access — it gets the OS image from the local image server at `172.22.0.1:9000` (see below). But once Ubuntu is provisioned and kubelet starts, DNS and container image pulls go through the internet.

`create-bridges.sh` enables IP forwarding and adds an iptables MASQUERADE rule to route provisioning subnet traffic through the management NIC:

```bash
# IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Allow provisioning subnet traffic through the management NIC
iptables -A FORWARD -i br-provision -o <LAN_INTERFACE> -j ACCEPT
iptables -A FORWARD -i <LAN_INTERFACE> -o br-provision -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -s 172.22.0.0/24 ! -d 172.22.0.0/24 -o <LAN_INTERFACE> -j MASQUERADE
```

**`LAN_INTERFACE` must be set correctly in `.env`** — it must match your actual outbound interface (`ip route show default`). On the MINISFORUM X1 Pro 370 this is `enp197s0`, not `enp1s0`. Wrong interface = VMs get no internet = `ImagePullBackOff` on every pod.

Rules are saved via `netfilter-persistent` and survive reboots.

---

## OS image server — why images are served locally

The IPA ramdisk that Ironic boots on each provisioning VM has **no DNS or internet access**. It is isolated to the `172.22.0.0/24` provisioning bridge and can only reach addresses on that subnet. If the `OSImage` URL points at an external host (e.g. `cloud-images.ubuntu.com`), the IPA agent will fail with:

```
NameResolutionError: Failed to resolve 'cloud-images.ubuntu.com'
```

`scripts/cache-os-image.sh` solves this by:

1. Downloading the Ubuntu 24.04 minimal image to `/srv/os-images/` on the host
2. Starting an `os-image-server` systemd service (Python HTTP server on `172.22.0.1:9000`)

The `OSImage` resource points at `http://172.22.0.1:9000/ubuntu-24.04-minimal-cloudimg-amd64.img` — reachable by the IPA ramdisk over the bridge with no DNS required.

This also cuts provisioning time from 8+ minutes (downloading from the internet) to ~40 seconds (local disk read over a virtual bridge).

---

## Sushy Tools endpoint

Sushy Tools listens on `172.22.0.1:8000` (the bridge IP). The Redfish URL for each VM is:

```
http://172.22.0.1:8000/redfish/v1/Systems/<vm-uuid>/
```

This address is reachable from Ironic, which runs inside the cluster and is attached to `br-provision` via Multus. `disableCertificateVerification: true` is set on all BareMetalHosts because Sushy Tools serves plain HTTP — there is no certificate.

**Important**: The BMC address scheme must be `redfish+http://` (not `redfish://`). The `redfish://` scheme forces HTTPS, causing an immediate SSL handshake failure against a plain HTTP endpoint.

---

## vCP DHCP proxy static assignment

Unlike a traditional DHCP server that hands out addresses from a pool, the vCP DHCP proxy does **static assignment** — it only responds to DHCP requests from MACs that have a matching `metal3.vcluster.com/ip-address` annotation on their BareMetalHost. Requests from unknown MACs are ignored.

This means every BareMetalHost must have:

```yaml
annotations:
  metal3.vcluster.com/ip-address: "172.22.0.11/24"   # unique per host
  metal3.vcluster.com/gateway: "172.22.0.1"
  metal3.vcluster.com/dns-servers: "8.8.8.8,1.1.1.1"
```

`hack/generate-bmh.sh` adds these automatically by assigning sequential IPs starting at `VM_IP_START`.

---

## The two 5G NICs on the MINISFORUM X1 Pro 370

- **enp197s0**: management traffic — SSH, vCluster Platform UI, internet. Connected to LAN/router.
- Second NIC (varies): not used in the basic demo. Could be enslaved to `br-provision` to expose the provisioning segment to physical lab machines, but unnecessary here.

Check your NIC names:

```bash
ip -brief link show
ip route show default   # shows which NIC carries internet traffic — use this for LAN_INTERFACE
```

---

## Checking for conflicts with the libvirt default network

The libvirt default network uses `192.168.122.0/24` on `virbr0` — no conflict with `172.22.0.0/24`. Check anyway:

```bash
sudo virsh net-list --all
sudo virsh net-dumpxml default
```

If any existing libvirt network uses `172.22.x.x`, change `PROVISION_IP` and `PROVISION_CIDR` in `.env` before running `create-bridges.sh`.
