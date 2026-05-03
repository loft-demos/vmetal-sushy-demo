# Customer + Rack Auto Nodes

This document explains the current best-fit model for customer-aware bare metal scheduling in this repo.

Use this alongside [customer-rack-topology.md](./customer-rack-topology.md):

- `customer-rack-topology.md` explains how Redfish discovery produces physical inventory.
- This document explains how the generated `NodeProvider` turns that physical inventory into schedulable pools for vCluster Auto Nodes.

## Mental model

There are three layers:

1. `BareMetalHost` labels describe physical facts only.
2. `NodeProvider.nodeTypes` define schedulable pools, usually `rack × size`.
3. `privateNodes.autoNodes.nodeTypeSelector` targets those pools by customer assignment and optional physical constraints.

The split is intentional:

- physical topology stays on the `BareMetalHost`
- customer assignment lives on `NodeType.properties`

That keeps rack handoff and customer reassignment at the schedulable-pool layer instead of the hardware-inventory layer.

## BareMetalHost labels

Each generated `BareMetalHost` carries labels like:

```yaml
metadata:
  labels:
    demo: vmetal
    topology.vcluster.com/az: us-va-blacksburg-dc1
    topology.vcluster.com/row: row-1
    topology.vcluster.com/rack: rack-a
    inventory.vcluster.com/size: large
    inventory.vcluster.com/accelerator: h100
```

These labels are physical-only:

- `topology.vcluster.com/*` describes placement
- `inventory.vcluster.com/*` describes hardware shape

Customer assignment is not stored on the `BareMetalHost`.

## NodeProvider pool model

The generated `NodeProvider` is named for the connected DC cluster:

```yaml
metadata:
  name: us-va-blacksburg-dc1
```

Its `nodeTypes` represent rack-scoped pools:

```yaml
- name: rack-a-large-pool
  bareMetalHosts:
    selector:
      matchLabels:
        demo: vmetal
        topology.vcluster.com/az: us-va-blacksburg-dc1
        topology.vcluster.com/row: row-1
        topology.vcluster.com/rack: rack-a
        inventory.vcluster.com/size: large
        inventory.vcluster.com/accelerator: h100
  properties:
    vcluster.com/customer: customer-a
    vcluster.com/az: us-va-blacksburg-dc1
    vcluster.com/row: row-1
    vcluster.com/rack: rack-a
    vcluster.com/profile: large
    vcluster.com/accelerator: h100
```

That gives each pool two meanings:

- `bareMetalHosts.selector` answers: “which machines belong to this pool?”
- `properties` answers: “which tenants are allowed to target this pool?”

## What Auto Nodes selects

The templates still expose:

- `customerSelector`: optional primary scope
- `rackSelector`: optional additional narrowing filter

Those selectors now filter `NodeType.properties`, not `BareMetalHost` labels directly.

### Dynamic template

`manifests/platform/vmetal-template.yaml` selects the DC-scoped provider and applies optional customer/rack filters:

```yaml
parameters: |
  kubernetesVersion: v1.34.7
  cpuLimit: "5"
  customerSelector: "customer-a"
  rackSelector: ""
```

That means:

- only node types with `vcluster.com/customer=customer-a` are eligible
- any rack assigned to `customer-a` can satisfy the request

With a rack pin:

```yaml
parameters: |
  kubernetesVersion: v1.34.7
  cpuLimit: "5"
  customerSelector: "customer-a"
  rackSelector: "rack-a"
```

That means:

- only `customer-a` pools are eligible
- only `rack-a` within that assigned set can be claimed

### Static template

`manifests/platform/vmetal-static-template.yaml` works the same way, but with explicit quantities per profile:

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
- source them from any rack pool currently assigned to `customer-a`

## Why this scales better

The pool model avoids the worst combinatorial explosion:

- poor fit: `customer × rack × size`
- better fit: `rack × size`

Customer assignment changes still happen, but they update `NodeType.properties` instead of exploding the number of node types or forcing `BareMetalHost` relabeling.

## Reassignment workflow

For a rack handoff story:

1. Update `configs/rack-assignments.csv`
2. Re-render the provider:

```bash
python3 hack/generate-node-provider-pools.py \
  --rack-topology configs/rack-topology.csv \
  --rack-assignments configs/rack-assignments.csv \
  --output manifests/platform/node-provider-customer-topology.yaml
```

3. Re-apply the provider:

```bash
kubectl apply -f manifests/platform/node-provider-customer-topology.yaml
```

The `BareMetalHost` labels stay unchanged because the physical placement did not move.

## Provisioning chain

Once a selector matches a pool, the provisioning chain is:

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
