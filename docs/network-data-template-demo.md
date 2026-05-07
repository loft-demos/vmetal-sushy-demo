# Network Data Template Demo

This runbook adds a credible demo lane for reusable bootstrap templating in
vMetal, with a particular focus on `network-data-template`.

## Why this matters

The current repo already demonstrates centralized image selection and inline
cloud-init through `vcluster.com/os-image`, `vcluster.com/ssh-keys`, and
`vcluster.com/user-data` on the NodeProvider.

What it does not show yet is the stronger operator story:

- bootstrap logic is standardized once
- network configuration is standardized once
- per-machine values are rendered at provisioning time
- teams consume the platform behavior without hand-writing cloud-init or
  network config per server

That is often the more realistic conversation with infrastructure teams,
especially when they are worried about DNS, gateways, routable subnets, and
host naming consistency.

## Verified baseline

As of May 6, 2026, the public vMetal docs explicitly document:

- `vcluster.com/user-data`
- `vcluster.com/user-data-template`
- `vcluster.com/user-data-template-secret`
- `metal3.vcluster.com/network-data`

The same public docs do not yet show a dedicated
`vcluster.com/network-data-template-secret` section.

For this repo, treat the `network-data-template` story as an optional demo lane
that depends on the vMetal build you are showing. If your build exposes a
network template property, use the examples below. If it does not, fall back to
`metal3.vcluster.com/network-data` and explain that the template variant is the
natural extension of the same idea.

Within vMetal, the correct templating property for this flow is
`vcluster.com/network-data-template-secret`, and it can be set on a
`NodeProvider`, `NodeType`, and/or `NodeEnvironment`.

Official references:

- `vMetal Configuration`: https://vmetal.ai/docs/configuration/
- `vMetal Architecture`: https://vmetal.ai/docs/architecture

## Demo goal

Show that the platform can render node-specific network configuration from a
reusable template rather than forcing operators to hardcode addresses or copy
cloud-init snippets around.

The ideal talk track is:

> "The operator defines the network model once. At provisioning time, vMetal
> renders the final network-data for each machine using the allocated IP,
> gateway, DNS, host identity, tenant context, and claim metadata."

## What to show live

1. Open [manifests/platform/node-provider.yaml](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/manifests/platform/node-provider.yaml).
2. Explain that the repo currently uses inline `vcluster.com/user-data`.
3. Introduce the reusable-template variant:
   - `vcluster.com/user-data-template` or `vcluster.com/user-data-template-secret`
   - `metal3.vcluster.com/network-data` today
   - `vcluster.com/network-data-template-secret` for reusable secret-backed
     network-data templating
4. Provision a node and inspect the resulting `NodeClaim`, `Machine`, and any
   generated host-cluster Secrets that contain rendered bootstrap artifacts.
5. Call out that the template is shared while the rendered result is
   machine-specific.

## Recommended demo shape

Use a split story:

- `user-data-template-secret` carries host bootstrap behavior
- `network-data-template` carries interface, address, route, and DNS layout

That separation is easier to explain than one massive cloud-init blob and feels
closer to how real platform teams think about ownership boundaries.

## Example: provider properties

This is the shape worth showing in the demo, even if your exact property names
vary by build:

```yaml
properties:
  vcluster.com/os-image: ubuntu-noble-bootstrap
  vcluster.com/ssh-keys: admin-macbook
  vcluster.com/user-data-template-secret: vmetal-bootstrap-template

  # For reusable network-data templating:
  vcluster.com/network-data-template-secret: dhcp-network-template

  # Otherwise fall back to a complete rendered blob:
  # metal3.vcluster.com/network-data: |
  #   version: 2
  #   ethernets:
  #     eno1:
  #       dhcp4: false
  #       addresses:
  #         - 172.22.0.11/24
  #       routes:
  #         - to: default
  #           via: 172.22.0.1
  #       nameservers:
  #         addresses: [172.22.0.1]
```

## Example: secret-backed user-data template

The user-data template path is documented publicly today, so this is the safer
template mechanism to show if you want a fully grounded example.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vmetal-bootstrap-template
  namespace: vcluster-platform
  labels:
    vcluster.com/user-data-template-type: cloud-config
type: Opaque
stringData:
  template: |
    #cloud-config
    write_files:
      - path: /etc/vmetal-bootstrap
        permissions: "0644"
        content: |
          project={{ "{{ .Values.Project.Name }}" }}
          nodeclaim={{ "{{ .Values.NodeClaim.Name }}" }}
          rack={{ "{{ index .Values.Properties \"vcluster.com/rack\" }}" }}
          profile={{ "{{ index .Values.Properties \"vcluster.com/profile\" }}" }}
    runcmd:
      - hostnamectl set-hostname "{{ "{{ .Values.NodeClaim.Name }}" }}"
```

The public docs verify the top-level `Values` object for user-data templates.
The nested accessors shown above are representative examples for demo prep, so
adjust them to the exact object shape exposed by the build you are using.

## Example: secret-backed network-data template

This repo now includes a demo-oriented example at
[manifests/platform/network-data-template-secret.yaml](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/manifests/platform/network-data-template-secret.yaml).

Why this specific version fits the demo:

- it targets the repo's real Platform namespace: `vcluster-platform`
- it binds to the PXE/provisioning NIC via the BareMetalHost boot MAC
- it uses `ipv4_dhcp`, which matches how this demo already assigns addresses
  through the vMetal DHCP proxy
- it points DNS at `172.22.0.1`, which is the host bridge IP running dnsmasq
  for both `*.vdemo.local` and upstream lookups

Rendered behavior in this demo:

- the guest asks for DHCP on the provisioning bridge NIC
- the DHCP proxy returns the host-specific lease derived from
  `metal3.vcluster.com/ip-address`
- dnsmasq on `172.22.0.1` handles split-horizon DNS for the provisioned node

This is the concrete shape to demo for secret-backed network-data templating:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vmetal-dhcp-network-template
  namespace: vcluster-platform
  labels:
    vcluster.com/user-data-template-type: network-data
type: Opaque
stringData:
  data: |
    {
      "links": [
        {
          "id": "nic0",
          "type": "phy",
          "ethernet_mac_address": "{{ "{{ index .Values.BareMetalHost \"spec\" \"bootMACAddress\" }}" }}"
        }
      ],
      "networks": [
        {
          "id": "net0",
          "link": "nic0",
          "type": "ipv4_dhcp"
        }
      ],
      "services": [
        {
          "type": "dns",
          "address": "172.22.0.1"
        }
      ],
      "meta": {
        "host": "{{ "{{ index .Values.BareMetalHost \"metadata\" \"name\" }}" }}",
        "claim": "{{ "{{ .Values.NodeClaim.Name }}" }}",
        "project": "{{ "{{ .Values.Project }}" }}",
        "network": "br-provision",
        "gateway": "172.22.0.1"
      }
    }
```

What makes this a strong demo:

- the template is centralized in one Secret instead of repeated per machine
- the boot MAC is pulled from the selected `BareMetalHost`
- the rendered output is still unique per claim and project
- you can tell a clean story around DHCP today, then evolve to static
  addressing, per-rack DNS, or multi-NIC templates later

When you narrate this, anchor it to the values that matter:

- project or tenant identity
- node claim name
- selected rack or pool
- allocated IP or DHCP mode
- gateway
- DNS servers
- selected NIC identity via the BareMetalHost boot MAC

## Safe repo-level implementation strategy

For this demo repo, keep the default manifests unchanged for normal use and add
the template story as an explicit alternate path:

1. Keep the current inline `vcluster.com/user-data` in place for the default
   flow.
2. Use this runbook during demos to explain the secret-backed template variant.
3. Prepare a small one-off `NodeProvider`, `NodeType`, or `NodeEnvironment`
   patch before the call rather than changing the stock demo manifest for
   everyone.

That keeps the repo reliable while still letting you tell the more advanced
network automation story.

## Suggested live narration

Use language like this:

> "Today this repo uses inline cloud-init so the demo is self-contained. In a
> customer environment we'd usually move that into reusable templates. The
> bootstrap template handles host setup, and the network template binds the
> right NIC, DHCP or static behavior, DNS, and host identity per machine at
> claim time."

> "That gives the platform team one place to standardize networking while still
> letting the rendered result be different for every allocated server."

## If you want to make this fully runnable

The next step would be to add a runnable example in this repo using
`vcluster.com/network-data-template-secret`, then include:

- a concrete Secret manifest for the network template
- a NodeProvider patch that switches from inline `user-data` to
  `user-data-template-secret`
- a short verification section showing where the rendered artifacts appear on
  the host cluster
