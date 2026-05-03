# Customer + Rack Topology Flow

This runbook describes the current best-fit topology model in `vmetal-sushy-demo`.

For how that topology is consumed by `NodeProvider` node types and vCluster Auto Nodes, see [customer-rack-auto-nodes.md](./customer-rack-auto-nodes.md).

The key modeling choice is:

- `Redfish` carries physical topology such as rack placement.
- `BareMetalHost` labels carry physical facts only.
- a separate assignment map carries `rack -> customer assignment`
- the generated `NodeProvider` turns that into schedulable rack pools

That split is closer to real environments. BMCs usually know where a chassis is physically installed only if someone populated that metadata, while customer assignment normally lives in a CMDB, CRM, or an allocation service.

## Realistic Redfish payload shape

If you want a semi-real mock, the most natural place for rack location is the `Chassis` resource, not an invented OEM field on `ComputerSystem`.

Example:

```json
{
  "@odata.type": "#Chassis.v1_25_0.Chassis",
  "Id": "rack-a-u12",
  "Name": "GPU Sled 12",
  "ChassisType": "RackMount",
  "Location": {
    "Placement": {
      "Row": "row-1",
      "Rack": "rack-a",
      "RackOffsetUnits": "EIA_310",
      "RackOffset": 12
    }
  },
  "Links": {
    "ComputerSystems": [
      {
        "@odata.id": "/redfish/v1/Systems/2b034cba-c55c-4a41-b60b-3662644c53c1"
      }
    ]
  }
}
```

For this repo's automation, the discovery flow follows:

1. `Systems/<id>`
2. `Links.Chassis[0]`
3. `Chassis.Location.Placement.Rack`
4. `Systems/<id>/EthernetInterfaces`

That yields the `MAC + BMC address + rack` inputs needed for `BareMetalHost` creation.

## Stage 1 — Bulk onboarding

1. Copy the physical topology and customer assignment maps:

```bash
cp configs/rack-topology.csv.example configs/rack-topology.csv
cp configs/rack-assignments.csv.example configs/rack-assignments.csv
```

2. Discover inventory from Redfish and normalize it into the repo inventory format:

```bash
bash hack/discover-redfish-inventory.sh
```

3. Generate and apply `BareMetalHosts` using one shared BMC Secret:

```bash
BMC_SHARED_SECRET_NAME=redfish-shared-creds \
  bash hack/generate-bmh.sh | kubectl apply -f -
```

4. Render the data-center scoped `NodeProvider`:

```bash
python3 hack/generate-node-provider-pools.py \
  --rack-topology configs/rack-topology.csv \
  --rack-assignments configs/rack-assignments.csv \
  --output manifests/platform/node-provider-customer-topology.yaml
```

5. Apply the generated provider:

```bash
kubectl apply -f manifests/platform/node-provider-customer-topology.yaml
```

What this demonstrates:

- `BareMetalHost` creation is automated from a `(MAC, BMC address)` inventory
- physical topology is modeled with `topology.vcluster.com/*` and `inventory.vcluster.com/*` labels
- customer assignment is applied at the `NodeType` property layer
- a shared BMC Secret is possible for homogeneous racks

## Stage 2 — First tenant vCluster

1. Apply the template and Tenant A example:

```bash
kubectl apply -f manifests/platform/vmetal-customer-static-template.yaml
kubectl apply -f manifests/platform/vcluster-tenant-a-rack-a.yaml
```

2. Watch the provisioning chain:

```bash
kubectl get virtualclusterinstances -n p-default -w
kubectl get baremetalhosts -n metal3-system -w
kubectl get nodeclaims -A -w
kubectl get machines -A -w
```

The tenant example is configured for:

- `customerSelector: customer-a`
- `rackSelector: rack-a`
- `controlPlaneReplicas: "3"`
- `largeNodeCount: "1"`

That lines up with the prospect flow:

- HA control plane with embedded etcd
- one private bare-metal node provisioned through Metal3
- selectors constrained by customer assignment and optional rack at the `NodeType` layer

## Rack reassignment workflow

For a “rack moves from Customer A to Customer B” story, keep the workflow CRD-driven and visible:

1. Update `configs/rack-assignments.csv`
2. Re-render the provider:

```bash
python3 hack/generate-node-provider-pools.py \
  --rack-topology configs/rack-topology.csv \
  --rack-assignments configs/rack-assignments.csv \
  --output manifests/platform/node-provider-customer-topology.yaml
```

3. Re-apply the `NodeProvider`:

```bash
kubectl apply -f manifests/platform/node-provider-customer-topology.yaml
```

That gives you a credible “rack handoff is a pool-property change” narrative without pretending customer assignment is a native Redfish concept or forcing a relabel of every `BareMetalHost`.
