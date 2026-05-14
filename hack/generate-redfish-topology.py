#!/usr/bin/env python3
"""Generate mock Redfish chassis topology from vm-inventory.txt.

Input inventory formats supported:
  NAME UUID MAC PROFILE FIRMWARE RACK
  NAME UUID MAC PROFILE FIRMWARE RACK LAN_MAC
  NAME UUID MAC PROFILE FIRMWARE RACK CUSTOMER
  NAME UUID MAC PROFILE FIRMWARE RACK LAN_MAC CUSTOMER
  NAME UUID MAC PROFILE FIRMWARE RACK CUSTOMER BMC_ADDRESS
  NAME UUID MAC PROFILE FIRMWARE RACK LAN_MAC CUSTOMER BMC_ADDRESS
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--default-row", default="row-1")
    parser.add_argument("--rack-offset-start", type=int, default=12)
    parser.add_argument("--rack-offset-step", type=int, default=2)
    parser.add_argument("--rack-offset-units", default="EIA_310")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    inventory_path = Path(args.inventory)
    output_path = Path(args.output)

    rack_counts: dict[str, int] = defaultdict(int)
    systems: dict[str, dict[str, object]] = {}
    chassis: dict[str, dict[str, object]] = {}

    for raw_line in inventory_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        parts = line.split()
        if len(parts) < 6:
            raise ValueError(f"Inventory line must contain at least 6 columns: {raw_line}")

        name, uuid, mac, profile, firmware, rack = parts[:6]
        rack_counts[rack] += 1
        slot_index = rack_counts[rack] - 1
        rack_offset = args.rack_offset_start + (slot_index * args.rack_offset_step)
        chassis_id = f"{rack}-u{rack_offset:02d}"

        systems[uuid] = {
            "name": name,
            "uuid": uuid,
            "mac": mac,
            "profile": profile,
            "firmware": firmware,
            "rack": rack,
            "row": args.default_row,
            "rack_offset": rack_offset,
            "rack_offset_units": args.rack_offset_units,
            "chassis_id": chassis_id,
        }

        chassis[chassis_id] = {
            "Id": chassis_id,
            "Name": f"{rack} slot {rack_offset}",
            "ChassisType": "RackMount",
            "Location": {
                "Placement": {
                    "Row": args.default_row,
                    "Rack": rack,
                    "RackOffsetUnits": args.rack_offset_units,
                    "RackOffset": rack_offset,
                }
            },
        }

    payload = {
        "systems": systems,
        "chassis": chassis,
    }
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
