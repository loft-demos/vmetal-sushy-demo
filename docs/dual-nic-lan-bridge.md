# Dual-NIC VM LAN Bridge

Use this layout when the host has two physical NICs and you want:

- Metal3/Ironic provisioning traffic to stay private on `br-provision`
- provisioned VM nodes to get normal LAN IPs on a second NIC
- SSH to the Ubuntu host to stay on its existing management NIC

## Recommended topology

- `LAN_INTERFACE`: the host's current SSH/uplink NIC
- `LAN_VM_INTERFACE`: a second physical NIC dedicated to the VM LAN bridge
- `PROVISION_BRIDGE`: `br-provision`
- `LAN_VM_BRIDGE`: `br-lan`

That means:

- the host keeps its current IP and default route on `LAN_INTERFACE`
- `br-provision` stays host-only for PXE, DHCP, Redfish, and the image server
- `br-lan` bridges the second NIC so provisioned nodes can use the real LAN

## Example `.env`

```bash
LAN_INTERFACE=enp197s0
LAN_VM_INTERFACE=enp198s0
LAN_VM_BRIDGE=br-lan

PROVISION_BRIDGE=br-provision
PROVISION_IP=172.22.0.1
PROVISION_CIDR=172.22.0.0/24
```

## Bring up the bridges

```bash
bash scripts/create-bridges.sh
```

What this does:

- creates `br-provision` with `172.22.0.1/24`
- keeps NAT from `br-provision` out through `LAN_INTERFACE`
- creates `br-lan` and enslaves `LAN_VM_INTERFACE` to it
- refuses to enslave `LAN_INTERFACE`, so the host SSH path stays intact

## Create the VMs

```bash
bash scripts/create-vms.sh
```

When `LAN_VM_BRIDGE` is set, each VM gets:

- NIC1 on `br-provision` for PXE/Ironic
- NIC2 on `br-lan` for workload/LAN traffic

The provisioning NIC stays first so `bootMACAddress` still maps to the PXE
interface.

## Post-Boot Node Networking

The current demo no longer relies on NodeProvider `user-data` to rewrite
netplan or pin kubelet. Instead:

- the `BareMetalHost` still carries the provisioning IP/gateway/DNS inputs
- the `BareMetalHost` also carries `lan.vcluster.com/mac` as the LAN NIC hint
- the `NodeProvider` references a `network-data-template-secret`
- that template configures only the LAN NIC in the installed OS

This means the running node naturally comes up on its LAN address
(`192.168.50.x`) instead of the provisioning subnet (`172.22.0.x`).

Operationally, that also means:

- PXE, Ironic, and image delivery still use `br-provision`
- the installed node is managed on its LAN IP
- SSH to the running node should use `192.168.50.x`, not `172.22.0.x`

## Teardown

`bash scripts/reset-demo.sh` still removes the provisioning bridge by default.
It leaves `br-lan` alone unless you explicitly ask for it:

```bash
bash scripts/reset-demo.sh --remove-lan-bridge
```
