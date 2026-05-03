# Customer + Rack Topology Flow

This runbook adds a more realistic inventory and tenancy model on top of the existing `vmetal-sushy-demo` repo.

For how that topology is consumed by `NodeProvider` node types and vCluster Auto Nodes, see [customer-rack-auto-nodes.md](./customer-rack-auto-nodes.md).

The key modeling choice is:

- `Redfish` carries physical topology such as rack placement.
- A separate assignment map carries `customer -> rack` assignment.

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
      "Row": "row-7",
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
    ],
    "ManagedBy": [
      {
        "@odata.id": "/redfish/v1/Managers/BMC"
      }
    ]
  }
}
```

For this repo's automation, the script follows:

1. `Systems/<id>`
2. `Links.Chassis[0]`
3. `Chassis.Location.Placement.Rack`
4. `Systems/<id>/EthernetInterfaces`

That yields the `MAC + BMC address + rack` inputs needed for BareMetalHost creation.

## Stage 1 — Bulk onboarding

1. Copy the rack assignment map and adjust it:

```bash
cp configs/rack-assignments.csv.example configs/rack-assignments.csv
```

2. Discover inventory from Redfish and normalize it into the repo inventory
format:

```bash
bash hack/discover-redfish-inventory.sh
```

3. Generate and apply BareMetalHosts using one shared BMC Secret:

```bash
BMC_SHARED_SECRET_NAME=redfish-shared-creds \
  bash hack/generate-bmh.sh | kubectl apply -f -
```

4. Apply the customer+rack aware NodeProvider:

```bash
kubectl apply -f manifests/platform/node-provider-customer-topology.yaml
```

What this demonstrates:

- BareMetalHost creation is automated from a `(MAC, BMC address)` inventory.
- `vmetal-customer` + `vmetal-rack` labels provide clean topology scoping.
- A shared BMC Secret is possible for homogeneous racks.

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
- selectors constrained by customer and rack at the NodeType layer

## Rack reassignment workflow

For a "rack moves from Customer A to Customer B" story, keep the workflow CRD-driven and visible:

1. Update `configs/rack-assignments.csv`
2. Re-run `bash hack/discover-redfish-inventory.sh`
3. Re-apply BMHs:

```bash
BMC_SHARED_SECRET_NAME=redfish-shared-creds \
  bash hack/generate-bmh.sh | kubectl apply -f -
```

4. Update the matching rack nodeTypes in `manifests/platform/node-provider-customer-topology.yaml` so the `vcluster.com/customer` property and `bareMetalHosts.selector.matchLabels` reflect the new customer assignment
5. Re-apply the NodeProvider manifest

That gives you a credible "rack handoff is a label/selector change" narrative without pretending customer assignment is a native Redfish concept.
