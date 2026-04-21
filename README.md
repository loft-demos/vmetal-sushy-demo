![vMetal](docs/vmetal-logo.svg)

# vMetal Demo with Sushy Tools

This repository is a single-machine demo for **vMetal** on **vCluster Platform**, using **Sushy Tools** and **libvirt/KVM** to emulate Redfish-managed bare metal on one Ubuntu host. The point of the demo is not "Metal3 on a laptop" by itself. The point is to show that **vCluster Platform's vMetal feature** can provide and operate the bare-metal management stack while the local machine supplies emulated hardware to manage.

In this setup, **vCluster Platform** is the control-plane experience being demoed, and **vMetal** is the feature under test. **Sushy Tools** and **libvirt** are the local infrastructure shim that make the demo reproducible without real servers.

Naming note: this demo uses OpenStack **Sushy Tools** for Redfish. That is different from OpenStack **VirtualBMC**, which is IPMI-oriented, and also different from some KubeVirt demos that use a separate `virtbmc`/KubeVirtBMC component capable of serving Redfish.

## What This Demo Shows

- **vCluster Platform** provides the bare-metal workflow through **vMetal**
- **vMetal** deploys and manages **Metal3**, **Ironic**, DHCP, and Multus as a platform-managed stack
- **Sushy Tools** exposes Redfish endpoints for local libvirt VMs
- **libvirt VMs** act as stand-ins for physical servers (two sizes: small and large)
- The full demo runs on a single Ubuntu machine

## Architecture

```text
                                   +-----------------------------------+
                                   |         vCluster Platform         |
                                   |   running on vCluster Standalone  |
                                   |                                   |
                                   |   Bare Metal / vMetal feature     |
                                   +-------------------+---------------+
                                                       |
                                                       v
                                   +-----------------------------------+
                                   |              vMetal               |
                                   |  manages Metal3 / Ironic / DHCP   |
                                   |      and related bare-metal       |
                                   |          provisioning pieces       |
                                   +-------------------+---------------+
                                                       |
                                                       v
                                   +-----------------------------------+
                                   |         Redfish / BMC Layer       |
                                   |           Sushy Tools API         |
                                   +-------------------+---------------+
                                                       |
                                                       v
                                   +-----------------------------------+
                                   |          libvirt / KVM VMs        |
                                   |    emulated bare metal workers    |
                                   |        (3x small + 2x large)      |
                                   +-----------------------------------+

Host machine: Ubuntu 24.04 + libvirt/KVM + Sushy Tools + vCluster Standalone
```

## Prerequisites

### Host hardware

This demo is developed and sized for the **MINISFORUM X1 Pro 370**:

- AMD Ryzen AI 9 HX370 (AMD-V / KVM capable)
- 64 GB RAM
- 1 TB SSD (OS) + 2x 2 TB NVMe SSDs (recommend pointing `VM_IMAGE_DIR` at one of these)
- 2x 5G RJ45 ports (one for management, one optional for provisioning)

Any dedicated Ubuntu 24.04 machine with at least 32 GB RAM, KVM support, and ~200 GB of free disk will work. CPU virtualization must be enabled in BIOS/UEFI.

### Software

- Access to **vCluster Platform** with the **vMetal** feature available
- A **vCluster Standalone** binary suitable for the host
- A vCluster Platform license or access token as the vMetal features require the [Scale Enterprise tier](https://www.vcluster.com/docs/platform/free-vs-enterprise)

---

## Quickstart

Copy the environment file and edit it for your setup:

```bash
cp configs/.env.example .env
```

At minimum set these before proceeding:

- `VCP_LICENSE_TOKEN` — your Scale tier license token (see [free vs enterprise](https://www.vcluster.com/docs/platform/free-vs-enterprise)); vMetal requires the **Scale** enterprise tier
- `VCP_LOFT_HOST` — the FQDN for the Platform UI (e.g. `vcp.vdemo.local`); must match `VDEMO_DOMAIN`
- `VDEMO_DOMAIN` — local domain for wildcard DNS (e.g. `vdemo.local`)
- `GATEWAY_IP` — one free LAN IP outside your router's DHCP range (e.g. `192.168.1.200`); MetalLB assigns this to the Gateway
- `METALLB_IP_RANGE` — single IP or range for MetalLB (e.g. `192.168.1.200-192.168.1.200`)
- `LAN_IP` — the MINISFORUM's own LAN IP address; used by Mac DNS setup to reach dnsmasq
- `LAN_INTERFACE` — the MINISFORUM's management NIC name (e.g. `enp1s0`)
- `VM_IMAGE_DIR` — path for VM disk images; point at a 2 TB NVMe SSD for best performance

Then run each step in order:

### 1. Bootstrap the host

Installs packages, enables libvirtd, and adds your user to the `libvirt`/`kvm` groups.

```bash
bash scripts/bootstrap-host.sh
```

**Log out and back in** after this step so group membership takes effect.

Verify:

```bash
kvm-ok
sudo virsh list --all
```

### 2. Create the provisioning bridge

Creates `br-provision` (172.22.0.1/24) as an isolated Linux bridge with STP disabled. Also enables IP forwarding and adds a NAT masquerade rule via `LAN_INTERFACE` so provisioning VMs can reach the internet for DNS and container image pulls.

> **Set `LAN_INTERFACE` in `.env` before running.** Check your outbound interface with `ip route show default` — wrong value means VMs cannot pull container images.

```bash
bash scripts/create-bridges.sh
```

Verify:

```bash
ip addr show br-provision
ping -c 3 8.8.8.8   # should succeed (confirms NAT is working from provisioning subnet perspective)
```

### 3. Create the demo VMs

Creates 3 small VMs and 2 large VMs by default, with an optional medium profile
available via `.env`. All are attached to `br-provision`. Writes
`configs/vm-inventory.txt`.

```bash
bash scripts/create-vms.sh
```

Verify:

```bash
sudo virsh list --all
cat configs/vm-inventory.txt
```

### 4. Start Sushy Tools

Installs Sushy Tools into a Python venv and starts the Redfish emulator.

```bash
# Foreground (Ctrl+C to stop):
bash scripts/start-sushy-tools.sh

# OR as a persistent systemd service:
bash scripts/install-sushy-service.sh
```

Verify the Redfish endpoint is up and all VMs are visible:

```bash
curl http://172.22.0.1:8000/redfish/v1/Systems/ | jq .
```

### 5. Set up DNS and install vCluster Standalone + vCluster Platform

> **Requires vCluster Platform Scale tier.** vMetal is an enterprise feature.
> Set `VCP_LICENSE_TOKEN`, `GATEWAY_IP`, `METALLB_IP_RANGE`, `VDEMO_DOMAIN`, and
> `VCP_LOFT_HOST` in `.env` before running.
> See [free vs enterprise](https://www.vcluster.com/docs/platform/free-vs-enterprise).

**vCluster Platform requires a resolvable FQDN** — bare IPs cause cookie and OAuth
redirect failures. This demo uses a wildcard DNS approach so that every service
(`vcp.vdemo.local`, `argocd.vdemo.local`, ...) resolves automatically with no
per-entry `/etc/hosts` maintenance.

**How it works:**

```text
Mac browser → *.vdemo.local → dnsmasq on MINISFORUM → GATEWAY_IP
                                                            ↓
                                             Traefik Gateway (MetalLB IP, TLS)
                                                            ↓
                                        HTTP 80 → HTTPS 443 → HTTPRoute → svc
```

**Step 5a — Configure DNS on the MINISFORUM host** (installs dnsmasq):

```bash
bash scripts/install-dnsmasq.sh
```

This configures dnsmasq to resolve `*.vdemo.local → GATEWAY_IP` and binds it to the
management NIC and, when `br-provision` exists, the provisioning bridge as well.
That lets both your Mac and provisioned Private Nodes resolve `*.vdemo.local`
through the same host-side resolver. By default, the script forwards public
lookups to the DNS servers currently configured on `LAN_INTERFACE`; set
`UPSTREAM_DNS_SERVERS` in `.env` if you need to pin a specific resolver such as
your router.

**Step 5b — Configure DNS on your Mac** (one-time setup):

```bash
# Run on your Mac (not the MINISFORUM):
bash hack/setup-mac-dns.sh lan
```

This creates `/etc/resolver/vdemo.local` pointing at the MINISFORUM's LAN IP.
All `*.vdemo.local` hostnames resolve immediately — no `/etc/hosts` entries needed.

If you also use this demo over Tailscale, the same helper can switch modes cleanly:

```bash
# Home LAN
bash hack/setup-mac-dns.sh lan

# Travel / Tailscale
# Use the Tailscale IP of the machine that can answer DNS for *.vdemo.local
bash hack/setup-mac-dns.sh tailscale <tailscale-dns-ip>

# Inspect or remove the current resolver
bash hack/setup-mac-dns.sh status
bash hack/setup-mac-dns.sh off
```

Optional: set `TAILSCALE_DNS_IP` in `.env` on your Mac copy of the repo so you can run
`bash hack/setup-mac-dns.sh tailscale` without passing the IP each time. If your
Tailscale DNS path returns a different service IP than local `GATEWAY_IP`, also set
`TAILSCALE_EXPECTED_IP` for stricter verification.

**Step 5c — Install vCluster Standalone + Platform:**

```bash
bash scripts/install-vcluster.sh
```

The install script:

1. Renders `configs/vcluster.yaml` with your `.env` values
2. Runs the vCluster Standalone installer
3. Applies MetalLB `IPAddressPool` + `L2Advertisement` so the Gateway gets `GATEWAY_IP`
4. Uses cert-manager to issue a self-signed wildcard certificate for `*.vdemo.local`
5. Applies `GatewayClass`, `Gateway` (HTTP redirect + HTTPS wildcard listeners), and
   `HTTPRoute` resources for vCluster Platform
6. Waits for the Gateway to receive its external IP from MetalLB

Watch the Platform pods come up:

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml
kubectl -n vcluster-platform get pods -w
```

Access the Platform UI at `https://vcp.vdemo.local` from your Mac once the pods are
ready. The demo certificate is self-signed, so your browser will warn until you trust it
locally. The CLI works with:

```bash
vcluster platform login https://vcp.vdemo.local --insecure
```

If Platform is already installed and healthy, you can patch just the HTTPS pieces instead
of re-running the full installer:

```bash
source .env
KC="sudo KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml kubectl"

sed "s|VDEMO_DOMAIN_PLACEHOLDER|${VDEMO_DOMAIN}|g" manifests/gateway/tls-wildcard.yaml \
  | ${KC} apply -f -

${KC} -n traefik wait --for=condition=Ready certificate/vdemo-wildcard-cert --timeout=180s

for manifest in \
  manifests/gateway/gatewayclass.yaml \
  manifests/gateway/gateway.yaml \
  manifests/gateway/httproute-http-redirect.yaml \
  manifests/gateway/httproute-vcp.yaml
do
  sed "s|VDEMO_DOMAIN_PLACEHOLDER|${VDEMO_DOMAIN}|g" "${manifest}" | ${KC} apply -f -
done
```

To add another service later (Argo CD, Grafana, etc.), create an `HTTPRoute` in its
namespace that attaches to the Gateway's `https` listener — the shared HTTP listener
already redirects to HTTPS.

> **Note:** vCluster Platform automatically connects the cluster it runs on as `loft-cluster`. No manual cluster import is needed. The NodeProvider and VirtualClusterInstance manifests already reference `loft-cluster`.

### 6. Create the Metal3 NodeProvider

```bash
kubectl apply -f manifests/platform/node-provider.yaml
```

This tells vMetal to deploy Metal3, Ironic, DHCP, and Multus as a platform-managed stack on `loft-cluster`. Watch until the NodeProvider is `Ready`:

```bash
kubectl get nodeprovider metal3-provider -w
```

Reference: [vCluster Platform Metal3 NodeProvider docs](https://www.vcluster.com/docs/platform/administer/node-providers/metal3)

### 7. Register the fake servers

Generate and apply the BareMetalHost and Secret manifests from the VM inventory:

```bash
bash hack/generate-bmh.sh | kubectl apply -f -
```

This creates one `BareMetalHost` and one BMC credentials `Secret` in `metal3-system` for each VM.
By default, the generated `BareMetalHost` annotations point DNS at `PROVISION_IP`
(`172.22.0.1` by default), so provisioned nodes can resolve `vcp.vdemo.local`
through the host's dnsmasq. Override with `PROVISION_DNS_SERVERS` if you need a
different resolver list.

Monitor the servers progressing through the bare-metal lifecycle:

```bash
kubectl -n metal3-system get baremetalhost -w
# States: registering → inspecting → available
```

### 8. Cache the OS image locally

The IPA ramdisk running inside provisioning VMs has no DNS or internet access — it is isolated on the provisioning bridge (`172.22.0.0/24`). The OS image must be served from the host so Ironic can reach it. Caching it locally also cuts provisioning time to ~40 seconds.

```bash
bash scripts/cache-os-image.sh
```

By default this downloads Ubuntu 24.04 minimal (~500 MB) to `/srv/os-images/`,
starts an `os-image-server` systemd service on `http://172.22.0.1:9000/`, and
generates `manifests/platform/os-images/ubuntu-noble.yaml`.

Why keep the minimal image as the default:
- It provisions faster and pulls less over the local bridge.
- It is enough for a clean worker-node demo where cloud-init or DaemonSets add the rest.
- It keeps disk and cache usage down when you are recreating nodes often.

When to use a different image:
- Use `ubuntu-server` if you want closer parity with the `vcluster-bare-metal-with-kubevirt` example or you rely on packages and defaults present in the full server cloud image.
- Use a custom image if you want packages pre-baked before first boot.

Examples:

```bash
# Full Ubuntu server image, cached locally and exposed through the same image server
bash scripts/cache-os-image.sh ubuntu-server

# Custom image with extra packages, then publish it as an OSImage
sudo apt-get install -y libguestfs-tools
bash scripts/build-custom-os-image.sh \
  --name ubuntu-noble-observability \
  --display-name "Ubuntu 24.04 LTS (Observability Tools)" \
  --packages qemu-guest-agent,curl,jq,nfs-common
```

### 9. Apply the OSImage, choose a template, and create a VirtualClusterInstance

Apply either demo path below, or both if you have enough BareMetalHosts available.

```bash
# OSImage — tells vMetal where to find the Ubuntu image (served from local cache)
kubectl apply -f manifests/platform/os-image.yaml

# Dynamic VirtualClusterTemplate — on-demand bare metal pool
kubectl apply -f manifests/platform/vmetal-template.yaml

# Dynamic VirtualClusterInstance — starts with a small-node class and scales within cpuLimit
kubectl apply -f manifests/platform/vcluster-vmetal.yaml

# Static VirtualClusterTemplate — fixed-size bare metal pools per node class
kubectl apply -f manifests/platform/vmetal-static-template.yaml

# Static VirtualClusterInstance — defaults to 1 small node + 1 large node
kubectl apply -f manifests/platform/vcluster-vmetal-static.yaml
```

The dynamic demo uses `vmetal-template` and starts at Kubernetes v1.34.1. It automatically claims an available `small-node` BareMetalHost and can scale that pool on demand up to the configured `cpuLimit`.

The static demo uses `vmetal-static-template` and exposes a quantity parameter for each node type (`small`, `medium`, `large`). By default it requests one `small-node` and one `large-node`, which is closer to the fixed reserved-capacity shape we usually see with AI clouds. Keep the requested quantities aligned with the available BareMetalHosts in your local inventory.

Watch the node claim progress:

```bash
kubectl get nodeclaims -A -w
kubectl -n metal3-system get baremetalhost -w
# States: available → provisioning → provisioned
```

Once provisioned, the node joins and system pods start running. The full cycle takes about a minute.

If you cached a non-default image, apply its generated manifest from
`manifests/platform/os-images/` and point the relevant node types in
`manifests/platform/node-provider.yaml` at that OSImage name:

```yaml
properties:
  vcluster.com/os-image: ubuntu-noble-server
```

---

## Expected Outcome

When the demo is working end to end:

- Local libvirt VMs simulate physical bare-metal servers
- Sushy Tools provides Redfish/BMC access to each VM
- vCluster Platform's vMetal feature manages the Metal3/Ironic stack
- BareMetalHost resources transition through `registering → inspecting → available`
- A `VirtualClusterInstance` claims one or more BareMetalHosts, provisions them with Ubuntu (~40s from local cache), and the nodes join as vCluster workers
- System pods (flannel, kube-proxy, coredns, konnectivity) come up `Running` on the bare metal node

**Short version**: emulated hardware locally, real bare-metal control flow in the platform.

## Demo Narrative

1. "These VMs are pretending to be physical servers."
2. "Sushy Tools gives them Redfish-compatible BMC endpoints."
3. "vCluster Platform's vMetal feature configures a Metal3 NodeProvider."
4. "The provider claims labeled BareMetalHosts and provisions them as Machines."
5. "Metal3, Ironic, DHCP, and related components stay in the background as platform-managed details."

---

## Repository Layout

```text
README.md
configs/
  .env.example          — all configurable variables; copy to .env
  sushy-tools.conf      — sushy-tools emulator config (deployed by start-sushy-tools.sh)
  vm-inventory.txt      — auto-generated by create-vms.sh; used by generate-bmh.sh
  vcluster.yaml         — vCluster Standalone config template (rendered by install-vcluster.sh)
docs/
  local-instructions.md — machine-specific step-by-step for the MINISFORUM X1 Pro 370
  design-notes.md       — architecture decisions, VM sizing, hardware notes
  networking.md         — bridge design, IP allocation, STP, NIC layout
  troubleshooting.md    — common issues and fixes
  vmetal-logo.svg       — vMetal logo (used in README)
scripts/
  bootstrap-host.sh         — install packages, enable libvirtd, add user to groups
  create-bridges.sh         — create br-provision Linux bridge + NAT for VM internet access
  create-vms.sh             — create 3 small + 2 large demo VMs
  destroy-vms.sh            — tear down demo VMs
  start-sushy-tools.sh      — install and run sushy-tools in foreground
  install-sushy-service.sh  — install sushy-tools as a systemd service
  cache-os-image.sh         — cache an image locally and generate a matching OSImage manifest
  build-custom-os-image.sh  — clone a cached image, install packages, and publish it
  install-image-server.sh   — install os-image-server systemd service
  install-dnsmasq.sh        — install dnsmasq for *.VDEMO_DOMAIN wildcard DNS on the LAN
  install-vcluster.sh       — install vCluster Standalone + Platform + Gateway + MetalLB
  reset-demo.sh             — full teardown (sushy + VMs + bridge)
manifests/
  gateway/
    gatewayclass.yaml       — GatewayClass for Traefik
    gateway.yaml            — wildcard *.VDEMO_DOMAIN Gateway with HTTP+HTTPS listeners
    httproute-http-redirect.yaml — HTTPRoute: redirect *.VDEMO_DOMAIN → HTTPS
    httproute-vcp.yaml      — HTTPRoute: https://vcp.VDEMO_DOMAIN → vcluster-platform svc
    tls-wildcard.yaml       — cert-manager Issuer + Certificate for *.VDEMO_DOMAIN
  platform/
    node-provider.yaml      — Metal3 NodeProvider for vCluster Platform
    os-image.yaml           — default OSImage: Ubuntu 24.04 minimal served from local cache
    os-images/              — generated alternative OSImage manifests
    vmetal-template.yaml         — dynamic VirtualClusterTemplate with kubernetesVersion + nodeType + cpuLimit
    vcluster-vmetal.yaml         — VirtualClusterInstance using vmetal-template (starts at v1.34.1)
    vmetal-static-template.yaml  — static VirtualClusterTemplate with per-node-type quantities
    vcluster-vmetal-static.yaml  — VirtualClusterInstance using vmetal-static-template
  baremetal/
    bmc-secret.yaml         — BMC credential Secret template
    baremetal-host.yaml     — BareMetalHost template
hack/
  generate-bmh.sh           — generate per-VM BareMetalHost + Secret YAML from inventory
  setup-mac-dns.sh          — manage /etc/resolver/VDEMO_DOMAIN on Mac (lan, tailscale, status, off)
```

---

## VM Profiles

| Profile | Count | vCPU | RAM | Disk | Label |
| --- | --- | --- | --- | --- | --- |
| Small | 3 | 2 | 4 GB | 40 GB | `vmetal-size: small` |
| Medium | 0 (optional) | 3 | 6 GB | 60 GB | `vmetal-size: medium` |
| Large | 2 | 4 | 8 GB | 80 GB | `vmetal-size: large` |

Adjust counts and sizes in `.env` before running `create-vms.sh`.

For best disk performance, set `VM_IMAGE_DIR` to a path on one of the 2 TB NVMe SSDs.

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for a full list. Quick checks:

### KVM or libvirt permission issues

```bash
kvm-ok
groups                        # confirm libvirt and kvm are listed
systemctl status libvirtd
sudo virsh list --all
```

### Networking conflicts

```bash
ip addr
sudo virsh net-list --all
sudo ss -ltnup | grep :67     # check for unexpected DHCP servers
```

### Redfish / Sushy misconfiguration

```bash
# Is sushy-tools running?
curl http://172.22.0.1:8000/redfish/v1/Systems/ | jq .

# Is the specific VM visible?
UUID=$(sudo virsh domuuid vmetal-small-1)
curl http://172.22.0.1:8000/redfish/v1/Systems/${UUID}/ | jq .
```

### BareMetalHost stuck in registering or inspection failed

```bash
kubectl -n metal3-system describe baremetalhost vmetal-small-1
kubectl -n metal3-system get events --sort-by=.lastTimestamp
```

Verify:

- `bootMACAddress` matches the VM NIC MAC (`sudo virsh domiflist <vm>`)
- Redfish address contains the full UUID path
- `disableCertificateVerification: true` is set

---

## Teardown

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml

# 1. Delete the vCluster (releases NodeClaim and BareMetalHost)
kubectl delete virtualclusterinstance vmetal-demo -n p-default

# 2. Delete BareMetalHosts and NodeProvider (undeploys Metal3/Ironic/DHCP)
kubectl delete baremetalhost --all -n metal3-system
kubectl delete nodeprovider metal3-provider

# 3. Tear down local infra (sushy-tools, VMs, bridge)
bash scripts/reset-demo.sh
```

> Resume from Step 3 of the Quickstart to re-run the demo without reinstalling vCluster Standalone or Platform.

---

## Non-Goals

- Production-grade bare-metal automation
- Multi-host HA design
- General-purpose Metal3 installation instructions independent of vCluster Platform

---

## References

- [vCluster Platform Bare Metal Overview](https://www.vcluster.com/docs/platform/administer/bare-metal/overview)
- [vCluster Platform Metal3 NodeProvider](https://www.vcluster.com/docs/platform/administer/node-providers/metal3)
- [Sushy Tools documentation](https://docs.openstack.org/sushy-tools/latest/)
- [Metal3 project](https://metal3.io/)

## License

See [LICENSE](./LICENSE).
