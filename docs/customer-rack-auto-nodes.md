# Customer + Rack Auto Nodes

This document explains how customer-aware and rack-aware capacity selection
works in the demo once `BareMetalHosts` have been discovered from Redfish and
labeled with topology metadata.

Use this alongside [customer-rack-topology.md](./customer-rack-topology.md):

- `customer-rack-topology.md` explains how inventory is built from Redfish and
  mapped into `BareMetalHost` objects.
- This document explains how `NodeProvider` node types and vCluster Auto Nodes
  consume that topology information during worker provisioning.

## Mental model

There are three layers:

1. `BareMetalHost` labels describe the discovered hardware inventory.
2. `NodeProvider.nodeTypes` translate those labels into schedulable capacity
   properties.
3. `privateNodes.autoNodes` selectors choose from that capacity using customer
   and optional rack filters.

The key split is:

- `customer` is the assignment / allocation dimension
- `rack` is the physical failure-domain dimension

That lets a customer span multiple racks while still allowing you to narrow a
node pool to one rack when you want a more explicit placement story.

## Inventory labels

Each discovered `BareMetalHost` carries labels like:

```yaml
metadata:
  labels:
    demo: vmetal
    vmetal-customer: customer-a
    vmetal-rack: rack-a
    vmetal-size: small
```

Those labels are derived from:

- Redfish `Chassis.Location.Placement.Rack`
- external `configs/rack-assignments.csv` assignment mapping
- hardware shape inferred from Redfish (`small`, `medium`, `large`)

## NodeProvider translation

The topology-aware provider model exposes those dimensions as node type
properties:

```yaml
properties:
  vcluster.com/customer: customer-a
  vcluster.com/rack: rack-a
  vcluster.com/profile: small
  vcluster.com/cpu: "2"
  vcluster.com/memory: 4Gi
```

That is the bridge between `BareMetalHost` labels and vCluster Auto Nodes.

## Selector behavior

The templates now support:

- `customerSelector`: optional primary scope
- `rackSelector`: optional additional narrowing filter

### Dynamic template

`manifests/platform/vmetal-template.yaml` works like this:

- if `customerSelector` is empty, any customer-assigned capacity is eligible
- if `customerSelector` is set, only matching customers are eligible
- if `rackSelector` is also set, the eligible set is reduced to those racks
- size is not constrained in the dynamic template; Karpenter can still choose
  larger matching node types if smaller ones are unavailable

Example:

```yaml
parameters: |
  kubernetesVersion: v1.34.7
  cpuLimit: "5"
  customerSelector: "customer-a"
  rackSelector: ""
```

That means:

- only `customer-a` capacity is considered
- capacity can come from any `BareMetalHost` assigned to `customer-a`

Example with a rack pin:

```yaml
parameters: |
  kubernetesVersion: v1.34.7
  cpuLimit: "5"
  customerSelector: "customer-a"
  rackSelector: "rack-a"
```

That means:

- only `customer-a` capacity is considered
- only `rack-a` within that customer-assigned set is eligible

### Static template

`manifests/platform/vmetal-static-template.yaml` works similarly, but with
fixed quantities per profile class:

```yaml
parameters: |
  kubernetesVersion: v1.34.7
  smallNodeCount: "2"
  mediumNodeCount: "1"
  largeNodeCount: "0"
  customerSelector: "customer-a"
  rackSelector: ""
```

That means:

- request 2 small nodes and 1 medium node
- source them from any `BareMetalHost` assigned to `customer-a`

And with explicit rack narrowing:

```yaml
parameters: |
  kubernetesVersion: v1.34.7
  smallNodeCount: "1"
  mediumNodeCount: "0"
  largeNodeCount: "1"
  customerSelector: "customer-a"
  rackSelector: "rack-a,rack-b"
```

That means:

- request 1 small node and 1 large node
- limit the eligible pool to `rack-a` and `rack-b`
- but still only within `customer-a` assignment

## Provisioning chain

Once a selector matches capacity, the provisioning chain is:

1. `VirtualClusterInstance`
2. Auto Nodes request
3. `NodeClaim`
4. Metal3-backed machine provisioning
5. `BareMetalHost` consumption
6. Node joins as a Private Node

Watch it with:

```bash
kubectl get virtualclusterinstances -n p-default -w
kubectl get nodeclaims -A -w
kubectl get machines -A -w
kubectl get baremetalhosts -n metal3-system -w
```

## Recommended usage patterns

### Customer-wide pool

Use when a customer can draw from multiple racks:

```yaml
customerSelector: "customer-a"
rackSelector: ""
```

### Customer + rack pin

Use when you want a stronger rack placement story:

```yaml
customerSelector: "customer-a"
rackSelector: "rack-a"
```

### Multi-rack customer failover window

Use when you want to show that the same customer allocation can span multiple
racks while still being bounded:

```yaml
customerSelector: "customer-a"
rackSelector: "rack-a,rack-b"
```

## Why rack stays optional

Keeping `rackSelector` optional is intentional:

- customer assignment is usually the higher-level commercial boundary
- rack is a physical placement boundary
- customers often span multiple racks
- forcing rack selection all the time would make the common multi-rack case
  awkward

So the natural model is:

- choose by customer first
- optionally narrow by rack

## Operational note

Do not put customer identity into the `BareMetalHost` name if you want rack
handoff to stay a label/selector change. The object name should reflect stable
physical identity, such as:

- `rack-a-u12-small`
- `rack-a-u18-large`
- `rack-b-u16-large`

Customer assignment should stay in labels and selectors:

- `vmetal-customer=customer-a`
- `vmetal-rack=rack-a`
