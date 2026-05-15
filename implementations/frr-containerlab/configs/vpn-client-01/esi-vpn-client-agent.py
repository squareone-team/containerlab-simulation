#!/usr/bin/env python3
import ipaddress
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


LISTEN_HOST = os.environ.get("ESI_VPN_CLIENT_AGENT_LISTEN", "198.18.4.20")
LISTEN_PORT = int(os.environ.get("ESI_VPN_CLIENT_AGENT_PORT", "15814"))
TRUSTED_GATEWAY = os.environ.get("ESI_VPN_GATEWAY_IP", "198.51.100.20")
WG_INTERFACE = os.environ.get("ESI_WG_INTERFACE", "wg0")
KEY_FILE = os.environ.get("ESI_WG_CLIENT_KEY", "/tmp/esi-vpn-client.key")
DEFAULT_ENDPOINT = os.environ.get("ESI_WG_ENDPOINT", "198.51.100.20:51820")
DEFAULT_ALLOWED_IPS = [
    item.strip()
    for item in os.environ.get(
        "ESI_WG_ALLOWED_IPS",
        "192.168.10.10/32,192.168.70.10/32,192.168.70.30/32",
    ).split(",")
    if item.strip()
]
MAX_BODY_BYTES = int(os.environ.get("ESI_VPN_CLIENT_MAX_BODY", "8192"))


def run(command, input_text=None, check=True):
    return subprocess.run(
        command,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=6,
        check=check,
    )


def disconnect():
    run(["ip", "link", "del", WG_INTERFACE], check=False)
    try:
        os.remove(KEY_FILE)
    except FileNotFoundError:
        pass


def validate_allowed_ips(values):
    if not isinstance(values, list):
        values = DEFAULT_ALLOWED_IPS
    normalized = []
    for value in values:
        network = ipaddress.ip_network(str(value), strict=False)
        normalized.append(str(network))
    return normalized


def connect(payload):
    private_key = str(payload.get("private_key", "")).strip()
    address = str(payload.get("address", "")).strip()
    server_pubkey = str(payload.get("server_pubkey", "")).strip()
    endpoint = str(payload.get("endpoint", DEFAULT_ENDPOINT)).strip() or DEFAULT_ENDPOINT
    allowed_ips = validate_allowed_ips(payload.get("allowed_ips", DEFAULT_ALLOWED_IPS))

    if not private_key or not address or not server_pubkey:
        raise ValueError("missing private_key, address, or server_pubkey")

    interface = ipaddress.ip_interface(address)
    if interface.version != 4:
        raise ValueError("only IPv4 WireGuard addresses are supported")

    disconnect()
    os.makedirs(os.path.dirname(KEY_FILE), exist_ok=True)
    old_umask = os.umask(0o177)
    try:
        with open(KEY_FILE, "w", encoding="utf-8") as handle:
            handle.write(private_key + "\n")
    finally:
        os.umask(old_umask)

    run(["ip", "link", "add", WG_INTERFACE, "type", "wireguard"])
    run(["ip", "addr", "replace", str(interface), "dev", WG_INTERFACE])
    run([
        "wg",
        "set",
        WG_INTERFACE,
        "private-key",
        KEY_FILE,
        "peer",
        server_pubkey,
        "endpoint",
        endpoint,
        "allowed-ips",
        ",".join(allowed_ips),
        "persistent-keepalive",
        "25",
    ])
    run(["ip", "link", "set", WG_INTERFACE, "up"])
    for route in allowed_ips:
        run(["ip", "route", "replace", route, "dev", WG_INTERFACE])


class Handler(BaseHTTPRequestHandler):
    server_version = "ESIVPNClientAgent/1.0"

    def _trusted(self):
        return self.client_address[0] in (TRUSTED_GATEWAY, "127.0.0.1", "::1")

    def _send_json(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        self._send_json(200, {"ok": True, "service": "esi-vpn-client-agent"})

    def do_POST(self):
        if not self._trusted():
            self._send_json(403, {"ok": False, "error": "untrusted_source"})
            return
        if self.path not in ("/connect", "/disconnect"):
            self.send_error(404)
            return
        if self.path == "/disconnect":
            disconnect()
            self._send_json(200, {"ok": True, "event": "disconnected"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"ok": False, "error": "bad_content_length"})
            return
        if length < 0 or length > MAX_BODY_BYTES:
            self._send_json(413, {"ok": False, "error": "request_too_large"})
            return

        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8", "replace"))
            connect(payload)
        except (ValueError, json.JSONDecodeError) as exc:
            self._send_json(400, {"ok": False, "error": str(exc)})
            return
        except (OSError, subprocess.SubprocessError) as exc:
            self._send_json(503, {"ok": False, "error": str(exc)})
            return

        self._send_json(200, {"ok": True, "event": "connected", "interface": WG_INTERFACE})

    def log_message(self, fmt, *args):
        return


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
