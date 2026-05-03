#!/usr/bin/env python3
"""Proxy a Redfish service and inject mock chassis topology.

This keeps the live Sushy/libvirt-backed Systems behavior but layers in
Chassis.Location.Placement and Systems->Chassis links from a local topology file.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import ssl
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


@dataclass
class UpstreamConfig:
    scheme: str
    host: str
    port: int
    verify_ssl: bool


class TopologyStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._mtime_ns: int | None = None
        self._data: dict[str, Any] = {"systems": {}, "chassis": {}}

    def load(self) -> dict[str, Any]:
        if not self.path.exists():
            self._data = {"systems": {}, "chassis": {}}
            self._mtime_ns = None
            return self._data

        mtime_ns = self.path.stat().st_mtime_ns
        if self._mtime_ns != mtime_ns:
            self._data = json.loads(self.path.read_text(encoding="utf-8"))
            self._mtime_ns = mtime_ns
        return self._data


def build_chassis_collection(base_path: str, topology: dict[str, Any]) -> dict[str, Any]:
    members = [
        {"@odata.id": f"{base_path.rstrip('/')}/{chassis_id}"}
        for chassis_id in sorted(topology.get("chassis", {}).keys())
    ]
    return {
        "@odata.type": "#ChassisCollection.ChassisCollection",
        "Name": "Chassis Collection",
        "Members@odata.count": len(members),
        "Members": members,
        "@odata.id": base_path,
        "@odata.context": "/redfish/v1/$metadata#ChassisCollection.ChassisCollection",
    }


def build_chassis_resource(base_path: str, chassis_id: str, topology: dict[str, Any]) -> dict[str, Any] | None:
    chassis = topology.get("chassis", {}).get(chassis_id)
    if chassis is None:
        return None

    systems = [
        {"@odata.id": f"/redfish/v1/Systems/{uuid}"}
        for uuid, info in topology.get("systems", {}).items()
        if info.get("chassis_id") == chassis_id
    ]
    payload = {
        "@odata.type": "#Chassis.v1_25_0.Chassis",
        "@odata.id": f"{base_path.rstrip('/')}/{chassis_id}",
        **chassis,
        "Links": {
            "ComputerSystems": systems,
        },
    }
    return payload


def patch_system_resource(payload: dict[str, Any], topology: dict[str, Any]) -> dict[str, Any]:
    system_id = payload.get("UUID") or payload.get("Id")
    if not system_id:
        return payload

    system_topology = topology.get("systems", {}).get(system_id)
    if not system_topology:
        return payload

    chassis_id = system_topology.get("chassis_id")
    if not chassis_id:
        return payload

    links = dict(payload.get("Links") or {})
    links["Chassis"] = [{"@odata.id": f"/redfish/v1/Chassis/{chassis_id}"}]
    payload["Links"] = links
    return payload


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "RedfishTopologyProxy/1.0"
    protocol_version = "HTTP/1.1"

    def _handle(self) -> None:
        path = urlsplit(self.path).path
        topology = self.server.topology_store.load()

        if self.command == "GET" and path in ("/redfish/v1/Chassis", "/redfish/v1/Chassis/"):
            payload = build_chassis_collection("/redfish/v1/Chassis", topology)
            self._send_json(200, payload)
            return

        if self.command == "GET" and path.startswith("/redfish/v1/Chassis/"):
            chassis_id = path.rstrip("/").split("/")[-1]
            payload = build_chassis_resource("/redfish/v1/Chassis", chassis_id, topology)
            if payload is None:
                self.send_error(404, "Chassis not found")
                return
            self._send_json(200, payload)
            return

        response = self._proxy_request()
        if response is None:
            return

        status, reason, headers, body = response

        content_type = next((value for key, value in headers.items() if key.lower() == "content-type"), "")
        if self.command == "GET" and path.startswith("/redfish/v1/Systems/") and content_type.startswith("application/json"):
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                payload = None
            if isinstance(payload, dict):
                body = json.dumps(patch_system_resource(payload, topology)).encode("utf-8")
                headers["Content-Type"] = "application/json"

        self.send_response(status, reason)
        for key, value in headers.items():
            if key.lower() in HOP_BY_HOP_HEADERS or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _proxy_request(self) -> tuple[int, str, dict[str, str], bytes] | None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length) if content_length else None

        upstream: http.client.HTTPConnection | http.client.HTTPSConnection
        if self.server.upstream.scheme == "https":
            context = ssl.create_default_context()
            if not self.server.upstream.verify_ssl:
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
            upstream = http.client.HTTPSConnection(
                self.server.upstream.host,
                self.server.upstream.port,
                timeout=30,
                context=context,
            )
        else:
            upstream = http.client.HTTPConnection(
                self.server.upstream.host,
                self.server.upstream.port,
                timeout=30,
            )

        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "host"
        }
        headers["Host"] = f"{self.server.upstream.host}:{self.server.upstream.port}"

        try:
            upstream.request(self.command, self.path, body=body, headers=headers)
            response = upstream.getresponse()
            payload = response.read()
            response_headers = {key: value for key, value in response.getheaders()}
            return response.status, response.reason, response_headers, payload
        except OSError as exc:
            self.send_error(502, f"Upstream Redfish request failed: {exc}")
            return None
        finally:
            upstream.close()

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        self._handle()

    def do_POST(self) -> None:  # noqa: N802
        self._handle()

    def do_PATCH(self) -> None:  # noqa: N802
        self._handle()

    def do_PUT(self) -> None:  # noqa: N802
        self._handle()

    def do_DELETE(self) -> None:  # noqa: N802
        self._handle()

    def log_message(self, format: str, *args: object) -> None:
        print(f"[redfish-topology-proxy] {self.address_string()} - {format % args}")


class ProxyServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], handler: type[ProxyHandler], upstream: UpstreamConfig, topology_store: TopologyStore) -> None:
        super().__init__(server_address, handler)
        self.upstream = upstream
        self.topology_store = topology_store


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default=os.environ.get("REDFISH_PROXY_LISTEN_IP", "0.0.0.0"))
    parser.add_argument("--listen-port", type=int, default=int(os.environ.get("REDFISH_PROXY_LISTEN_PORT", "8000")))
    parser.add_argument("--upstream-url", default=os.environ.get("REDFISH_UPSTREAM_URL", "http://127.0.0.1:8001"))
    parser.add_argument("--topology-file", default=os.environ.get("REDFISH_TOPOLOGY_FILE", "configs/redfish-topology.json"))
    parser.add_argument("--verify-upstream-ssl", action="store_true", default=os.environ.get("REDFISH_VERIFY_UPSTREAM_SSL", "").lower() in {"1", "true", "yes"})
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    upstream = urlsplit(args.upstream_url)
    if upstream.scheme not in {"http", "https"}:
        raise SystemExit("upstream-url must start with http:// or https://")
    host = upstream.hostname or "127.0.0.1"
    port = upstream.port or (443 if upstream.scheme == "https" else 80)

    server = ProxyServer(
        (args.listen_host, args.listen_port),
        ProxyHandler,
        upstream=UpstreamConfig(
            scheme=upstream.scheme,
            host=host,
            port=port,
            verify_ssl=args.verify_upstream_ssl,
        ),
        topology_store=TopologyStore(Path(args.topology_file)),
    )
    print(
        f"[redfish-topology-proxy] Listening on {args.listen_host}:{args.listen_port}, "
        f"proxying {args.upstream_url}, topology {args.topology_file}"
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
