#!/usr/bin/env python3
import ipaddress
import json
import os
import re
import ssl
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer


RADIUS_HOST = os.environ.get("ESI_RADIUS_HOST", "192.168.50.80")
RADIUS_PORT = int(os.environ.get("ESI_RADIUS_PORT", "1812"))
RADIUS_SECRET = os.environ.get("ESI_RADIUS_SECRET", "VpnRadiusSecret@2026")
RADIUS_NAS_ID = os.environ.get("ESI_RADIUS_NAS_ID", "vpn-gateway")

LISTEN_HOST = os.environ.get("ESI_VPN_LISTEN", "198.51.100.20")
LISTEN_PORT = int(os.environ.get("ESI_VPN_PORT", "8448"))
TLS_CERT = os.environ.get("ESI_VPN_TLS_CERT", "/etc/esi-vpn/tls/vpn.crt")
TLS_KEY = os.environ.get("ESI_VPN_TLS_KEY", "/etc/esi-vpn/tls/vpn.key")
TLS_ENABLED = os.environ.get("ESI_VPN_TLS", "1") == "1"
WG_INTERFACE = os.environ.get("ESI_WG_INTERFACE", "wg0")
SERVER_PUB = os.environ.get("ESI_WG_SERVER_PUB", "/etc/wireguard/server.pub")
STATE_FILE = os.environ.get("ESI_VPN_STATE", "/var/lib/esi-vpn/leases.json")
LOG_FILE = os.environ.get("ESI_VPN_LOG", "/var/log/esi-vpn-auth.log")

POOL_START = os.environ.get("ESI_VPN_POOL_START", "10.250.200.10")
POOL_END = os.environ.get("ESI_VPN_POOL_END", "10.250.200.200")

ROLE_PATTERN = re.compile(r"Filter-Id\s*=\s*\"?([A-Za-z0-9_-]+)\"?")


def log_event(event):
    with open(LOG_FILE, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def load_state():
    if not os.path.exists(STATE_FILE):
        return {}
    with open(STATE_FILE, "r", encoding="utf-8") as handle:
        return json.load(handle)


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as handle:
        json.dump(state, handle, sort_keys=True, indent=2)


def run_radius(user, password):
    payload = (
        f'User-Name = "{user}"\n'
        f'User-Password = "{password}"\n'
        f'NAS-Identifier = "{RADIUS_NAS_ID}"\n'
    )
    cmd = [
        "radclient",
        "-x",
        f"{RADIUS_HOST}:{RADIUS_PORT}",
        "auth",
        RADIUS_SECRET,
    ]
    proc = subprocess.run(
        cmd,
        input=payload,
        text=True,
        capture_output=True,
        timeout=6,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    accepted = "Access-Accept" in output
    role = ""
    match = ROLE_PATTERN.search(output)
    if match:
        role = match.group(1)
    return accepted, role, output.strip()


def allocate_ip(state, peer_key):
    if peer_key in state:
        return state[peer_key]["ip"]

    used = {entry["ip"] for entry in state.values() if "ip" in entry}
    start = ipaddress.ip_address(POOL_START)
    end = ipaddress.ip_address(POOL_END)
    current = start
    while current <= end:
        ip_str = str(current)
        if ip_str not in used:
            return ip_str
        current += 1
    return ""


def add_peer(peer_key, address):
    subprocess.run(
        ["wg", "set", WG_INTERFACE, "peer", peer_key, "allowed-ips", f"{address}/32"],
        check=False,
    )


def server_pubkey():
    try:
        with open(SERVER_PUB, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except FileNotFoundError:
        return ""


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/enroll":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length).decode("utf-8", "replace")
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            self.send_error(400)
            return

        username = str(data.get("username", "")).strip()
        password = str(data.get("password", "")).strip()
        peer_key = str(data.get("public_key", "")).strip()
        if not username or not password or not peer_key:
            self.send_error(400)
            return

        accepted, role, detail = run_radius(username, password)
        state = load_state()
        if accepted and role == "vpn-student":
            address = allocate_ip(state, peer_key)
            if not address:
                self.send_error(503)
                return
            add_peer(peer_key, address)
            state[peer_key] = {"user": username, "ip": address}
            save_state(state)
            response = {
                "ok": True,
                "address": f"{address}/32",
                "endpoint": "198.51.100.20:51820",
                "server_pubkey": server_pubkey(),
                "allowed_ips": ["192.168.10.10/32", "192.168.70.10/32", "192.168.70.30/32"],
            }
            status = 200
        else:
            response = {"ok": False, "role": role or "unknown"}
            status = 403

        log_event({
            "user": username,
            "role": role or "none",
            "accepted": accepted,
            "radius_result": "accepted" if accepted else "rejected",
        })

        body = json.dumps(response).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def main():
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    if TLS_ENABLED:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(TLS_CERT, TLS_KEY)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    log_event({"event": "vpn_enroll_start", "listen": f"{LISTEN_HOST}:{LISTEN_PORT}", "tls": TLS_ENABLED})
    server.serve_forever()


if __name__ == "__main__":
    main()
