# Networking Design

## Overview

This demo uses a single provisioning network (`172.22.0.0/24` by default) implemented as a Linux bridge on the Ubuntu host. All libvirt VMs attach to this bridge. Ironic (deployed by vMetal) provides DHCP and PXE on the same network. Sushy Tools listens on the host bridge IP so it is reachable from both the host and from within the cluster.

```
Host machine (Ubuntu 24.04)
│
├── enp1s0  (management NIC — SSH, UI, internet)
│     DHCP from your router / LAN
│
└── br-provision  (Linux bridge — isolated provisioning network)
      IP: 172.22.0.1/24
      │
      ├── vmetal-small-1 NIC (VM, 52:54:00:aa:00:00)
      ├── vmetal-small-2 NIC (VM, 52:54:00:aa:00:01)
      ├── vmetal-small-3 NIC (VM, 52:54:00:aa:00:02)
      ├── vmetal-large-1 NIC (VM, 52:54:00:bb:00:00)
      └── vmetal-large-2 NIC (VM, 52:54:00:bb:00:01)
```

The bridge is **isolated** — it has no physical NIC enslaved and no external routing. This keeps PXE/DHCP traffic contained and avoids conflicts with the LAN.

---

## Why a plain Linux bridge instead of a libvirt virtual network

libvirt's built-in virtual networks create their own dnsmasq DHCP server. For Metal3/Ironic, **Ironic must own DHCP** on the provisioning network (it uses DHCP to track which machine is PXE-booting and to assign IPs). Running two DHCP servers on the same segment causes random provisioning failures.

A plain Linux bridge avoids this: no DHCP is started by default, and Ironic (deployed by vMetal via the `dhcp` section of the NodeProvider) attaches to the bridge through a Multus `NetworkAttachmentDefinition`.

---

## Why STP must be disabled

Spanning Tree Protocol (STP) introduces a forwarding delay (typically 30 seconds) when a bridge port first comes up. During this delay, DHCP and PXE traffic is dropped. For VMs that PXE-boot and expect a DHCP response within a few seconds, STP causes the boot to fail entirely.

`create-bridges.sh` sets `bridge.stp no` via nmcli, which disables STP on the bridge.

---

## IP address allocation

| Address | Role |
|---|---|
| `172.22.0.1` | Host bridge IP; sushy-tools Redfish endpoint |
| `172.22.0.2` | DHCP VIP for the Ironic DHCP server (configured in `node-provider.yaml`) |
| `172.22.0.50–200` | Available for Ironic DHCP to hand to PXE-booting VMs |

These values are defaults. Override with `PROVISION_IP` / `PROVISION_CIDR` in `.env`.

---

## Sushy Tools endpoint

Sushy Tools listens on `0.0.0.0:8000` (or `PROVISION_IP:8000` if `SUSHY_LISTEN_IP` is set). The Redfish URL for each VM is:

```
http://172.22.0.1:8000/redfish/v1/Systems/<vm-uuid>/
```

This address must be reachable from Ironic, which runs inside vCluster. Ironic reaches it through the provisioning bridge because the bridge IP (`172.22.0.1`) is on the host and the Ironic pod is attached to `br-provision` via Multus.

`disableCertificateVerification: true` is set on all BareMetalHost resources because sushy-tools uses plain HTTP in this demo. There is no certificate to verify.

---

## The two 5G NICs on the MINISFORUM X1 Pro 370

The host has two 5G RJ45 ports. In this single-machine demo setup:

- **enp1s0** (or your primary NIC name): carries management traffic — SSH access, vCluster Platform UI, internet connectivity. Connected to your LAN/router.
- **enp2s0** (second NIC): not used in the basic single-machine demo. For a more realistic setup, you could enslave it to `br-provision` to give physical access to the provisioning segment from other machines on a lab network.

To check your NIC names:
```bash
ip -brief link show
```

Do not hard-code interface names in scripts — use `ip link` output or the interface name as shown by `nmcli device status`.

---

## Checking for conflicts with the libvirt default network

The libvirt default network typically uses `192.168.122.0/24` on `virbr0`. This does not conflict with `172.22.0.0/24`, but check anyway:

```bash
sudo virsh net-list --all
sudo virsh net-dumpxml default
```

If any existing libvirt network uses `172.22.x.x`, change `PROVISION_IP` and `PROVISION_CIDR` in `.env` before running `create-bridges.sh`.
