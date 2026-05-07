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


USER_DATA = """#cloud-config
write_files:
  - path: /etc/vcluster-common
    permissions: "0644"
    content: |
      common config
  - path: /usr/local/bin/configure-vdemo-node-bootstrap
    permissions: "0755"
    content: |
      #!/bin/sh
      set -eu

      iface="$(ip route show default 0.0.0.0/0 | awk 'NR==1 {print $5}')"
      [ -n "${iface}" ] || exit 1

      resolvectl domain "${iface}" '~vdemo.local'
      resolvectl default-route "${iface}" yes

      cert_tmp="$(mktemp)"
      tries=0
      while true; do
        if curl -fsSL "http://172.22.0.1:9000/vdemo-platform.crt" -o "${cert_tmp}"; then
          break
        fi
        tries=$((tries + 1))
        if [ "${tries}" -ge 20 ]; then
          echo "failed to download platform certificate after ${tries} attempts" >&2
          exit 1
        fi
        sleep 3
      done

      install -D -m 0644 "${cert_tmp}" /usr/local/share/ca-certificates/vdemo-platform.crt
      rm -f "${cert_tmp}"
      update-ca-certificates
      systemctl try-restart vcluster || true
  - path: /etc/systemd/system/vdemo-resolved-domain.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Configure vdemo.local DNS routing and trust the platform certificate
      Wants=network-online.target
      After=network-online.target systemd-resolved.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/configure-vdemo-node-bootstrap
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable --now vdemo-resolved-domain.service
"""


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


def indent(text: str, spaces: int) -> str:
    prefix = " " * spaces
    return "\n".join(f"{prefix}{line}" if line else prefix.rstrip() for line in text.splitlines())


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


def render_provider(provider_name: str, display_name: str, racks: list[RackTopology], assignments: dict[str, str]) -> str:
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
    vcluster.com/ssh-keys: admin-macbook
    # The stock demo keeps bootstrap behavior inline so the repo is runnable
    # end-to-end with no extra secrets. For a stronger operator story, see
    # docs/network-data-template-demo.md and swap this to
    # vcluster.com/user-data-template-secret plus, when supported by your
    # vMetal build, a network-data-template-based flow.
    vcluster.com/user-data: |
{indent(USER_DATA, 6)}

  metal3:
    clusterRef:
      cluster: loft-cluster
      namespace: metal3-system

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

    output = render_provider(args.provider_name, args.display_name, rack_topology, assignments)
    Path(args.output).write_text(output + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
