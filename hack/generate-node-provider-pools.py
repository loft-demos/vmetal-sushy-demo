#!/usr/bin/env python3
"""Generate a data-center scoped Metal3 NodeProvider from rack metadata.

This generator keeps BareMetalHost labels physical-only and emits rack-scoped
NodeTypes. Customer assignment is surfaced through NodeType properties, which
lets vCluster Auto Nodes target customer-assigned pools without relabeling the
hardware inventory itself.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RackTopology:
    rack: str
    row: str
    az: str


@dataclass(frozen=True)
class SizeProfile:
    name: str
    cpu: str
    memory: str
    accelerator: str


SIZE_PROFILES = (
    SizeProfile(name="small", cpu="2", memory="4Gi", accelerator="cpu-only"),
    SizeProfile(name="medium", cpu="3", memory="6Gi", accelerator="cpu-only"),
    SizeProfile(name="large", cpu="4", memory="8Gi", accelerator="h100"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rack-topology", required=True)
    parser.add_argument("--rack-assignments", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--provider-name", default="us-va-blacksburg-dc1")
    parser.add_argument("--display-name", default="vMetal Demo - Metal3 Provider (us-va-blacksburg-dc1)")
    parser.add_argument("--cluster-name", default="vmetal-cluster")
    parser.add_argument("--cluster-namespace", default="metal3-system")
    parser.add_argument("--ssh-key-ref", default="admin-bastion-host")
    parser.add_argument("--network-data-template-secret", default="vcluster-platform/vmetal-dual-nic-network-template")
    return parser.parse_args()


def read_rack_topology(path: Path) -> list[RackTopology]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            stripped = stripped.lstrip("#").strip()
        rows.append(stripped)

    racks: list[RackTopology] = []
    reader = csv.DictReader(rows)
    for row in reader:
        racks.append(
            RackTopology(
                rack=row["rack"].strip(),
                row=row["row"].strip(),
                az=row["az"].strip(),
            )
        )
    return racks


def read_rack_assignments(path: Path) -> dict[str, str]:
    assignments: dict[str, str] = {}
    if not path.exists():
        return assignments

    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            stripped = stripped.lstrip("#").strip()
        rows.append(stripped)

    reader = csv.DictReader(rows)
    for row in reader:
        assignments[row["rack"].strip()] = row["customer"].strip()
    return assignments


def render_node_type(rack: RackTopology, customer: str, size: SizeProfile) -> str:
    name = f"{rack.rack}-{size.name}-pool"
    return f"""\
      - name: {name}
        resources:
          cpu: "{size.cpu}"
          memory: {size.memory}
        bareMetalHosts:
          selector:
            matchExpressions:
              - key: demo
                operator: In
                values:
                  - vmetal
              - key: topology.vcluster.com/az
                operator: In
                values:
                  - {rack.az}
              - key: topology.vcluster.com/row
                operator: In
                values:
                  - {rack.row}
              - key: topology.vcluster.com/rack
                operator: In
                values:
                  - {rack.rack}
              - key: inventory.vcluster.com/size
                operator: In
                values:
                  - {size.name}
              - key: inventory.vcluster.com/accelerator
                operator: In
                values:
                  - {size.accelerator}
        properties:
          vcluster.com/customer: {customer}
          vcluster.com/az: {rack.az}
          vcluster.com/row: {rack.row}
          vcluster.com/rack: {rack.rack}
          vcluster.com/profile: {size.name}
          vcluster.com/accelerator: {size.accelerator}
          vcluster.com/cpu: "{size.cpu}"
          vcluster.com/memory: {size.memory}
"""


def render_provider(
    provider_name: str,
    display_name: str,
    cluster_name: str,
    cluster_namespace: str,
    ssh_key_ref: str,
    network_data_template_secret: str,
    racks: list[RackTopology],
    assignments: dict[str, str],
) -> str:
    node_types = "\n".join(
        render_node_type(rack, assignments.get(rack.rack, "unassigned"), size)
        for rack in racks
        for size in SIZE_PROFILES
    ).rstrip()

    return f"""\
# node-provider-customer-topology.yaml — data-center scoped Metal3 NodeProvider
#
# Rendered by hack/generate-node-provider-pools.py.
# Model:
#   - one NodeProvider per connected DC control-plane cluster
#   - BareMetalHost labels carry physical facts only
#   - NodeTypes represent schedulable rack/size pools
#   - customer assignment lives on NodeType properties
#
# Re-render after editing configs/rack-topology.csv or
# configs/rack-assignments.csv:
#   python3 hack/generate-node-provider-pools.py \\
#     --rack-topology configs/rack-topology.csv \\
#     --rack-assignments configs/rack-assignments.csv \\
#     --output manifests/platform/node-provider-customer-topology.yaml

apiVersion: management.loft.sh/v1
kind: NodeProvider
metadata:
  name: {provider_name}
spec:
  displayName: "{display_name}"

  properties:
    vcluster.com/os-image: ubuntu-noble-bootstrap
    vcluster.com/ssh-keys: {ssh_key_ref}
    # The namespaced network-data template secret configures only the LAN NIC
    # in the installed node OS. Provisioning traffic stays on br-provision and
    # the running node is managed on its LAN IP.
    vcluster.com/network-data-template-secret: {network_data_template_secret}

  metal3:
    clusterRef:
      cluster: {cluster_name}
      namespace: {cluster_namespace}

    deploy:
      multus:
        enabled: true
        helmValues: |
          namespace: kube-system

      metal3:
        enabled: true
        helmValues: |
          ironic:
            image:
              tag: release-32.0

      dhcp:
        enabled: true
        helmValues: |
          networkAttachmentDefinition:
            vip: 172.22.0.2/24
            config: |
              {{
                "cniVersion": "0.3.1",
                "type": "bridge",
                "bridge": "br-provision",
                "ipam": {{}}
              }}

    nodeTypes:
{node_types}
"""


def main() -> int:
    args = parse_args()
    rack_topology = read_rack_topology(Path(args.rack_topology))
    assignments = read_rack_assignments(Path(args.rack_assignments))
    if not rack_topology:
        raise SystemExit("No rack topology rows were found")

    output = render_provider(
        args.provider_name,
        args.display_name,
        args.cluster_name,
        args.cluster_namespace,
        args.ssh_key_ref,
        args.network_data_template_secret,
        rack_topology,
        assignments,
    )
    Path(args.output).write_text(output + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
