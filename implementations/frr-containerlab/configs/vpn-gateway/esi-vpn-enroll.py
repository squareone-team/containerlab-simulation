#!/usr/bin/env python3
import ipaddress
import json
import os
import re
import ssl
import subprocess
import time
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
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")
    except OSError:
        return


def load_state():
    if not os.path.exists(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        if not isinstance(state, dict):
            raise json.JSONDecodeError("state is not a dict", "", 0)
        return state
    except json.JSONDecodeError:
        backup = f"{STATE_FILE}.corrupt.{int(time.time())}"
        try:
            os.replace(STATE_FILE, backup)
        except OSError:
            backup = ""
        log_event({"event": "vpn_state_corrupt", "state_file": STATE_FILE, "backup": backup})
        return {}
    except OSError:
        return {}


def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, indent=2)
    except OSError as exc:
        log_event({"event": "vpn_state_save_failed", "error": str(exc)})
        return False
    return True


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
    try:
        proc = subprocess.run(
            cmd,
            input=payload,
            text=True,
            errors="replace",
            capture_output=True,
            timeout=6,
        )
    except subprocess.TimeoutExpired:
        return False, "", "", "radius_timeout"
    except FileNotFoundError:
        return False, "", "", "radclient_missing"
    except OSError:
        return False, "", "", "radius_error"

    output = (proc.stdout or "") + (proc.stderr or "")
    accepted = "Access-Accept" in output
    role = ""
    match = ROLE_PATTERN.search(output)
    if match:
        role = match.group(1)
    return accepted, role, output.strip(), ""


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
    try:
        subprocess.run(
            ["wg", "set", WG_INTERFACE, "peer", peer_key, "allowed-ips", f"{address}/32"],
            check=False,
        )
    except FileNotFoundError:
        return False
    return True


def server_pubkey():
    try:
        with open(SERVER_PUB, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except FileNotFoundError:
        return ""


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, status, html):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>ESI VPN Enrollment</title>
  <style>
    body { font-family: sans-serif; margin: 32px; line-height: 1.4; }
    code, pre { background: #f4f4f4; padding: 2px 4px; }
    pre { padding: 12px; }
    label { display: block; margin: 10px 0 4px; }
    input, textarea { width: 100%; max-width: 560px; }
    button { margin-top: 12px; }
    #output { white-space: pre-wrap; }
  </style>
</head>
<body>
  <h1>ESI VPN Enrollment</h1>
  <p>This endpoint accepts JSON on <code>POST /enroll</code> and returns a WireGuard config.</p>
  <p>Health check: <a href="/health">/health</a></p>

  <h2>Manual test</h2>
  <form id="enroll-form">
    <label>Username</label>
    <input id="username" required />
    <label>Password</label>
    <input id="password" type="password" required />
    <label>WireGuard public key</label>
    <textarea id="public_key" rows="3" required></textarea>
    <button type="submit">Enroll</button>
  </form>
  <pre id="output"></pre>

  <h2>CLI example</h2>
  <pre>curl -ks -X POST -H "Content-Type: application/json" \
  -d '{"username":"student1","password":"Student@2026","public_key":"PUBKEY"}' \
  https://198.51.100.20:8448/enroll</pre>

  <script>
    const form = document.getElementById("enroll-form");
    const output = document.getElementById("output");
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      output.textContent = "Sending request...";
      const payload = {
        username: document.getElementById("username").value,
        password: document.getElementById("password").value,
        public_key: document.getElementById("public_key").value,
      };
      try {
        const response = await fetch("/enroll", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        const text = await response.text();
        output.textContent = text;
      } catch (err) {
        output.textContent = String(err || "Request failed");
      }
    });
  </script>
</body>
</html>
"""
            self._send_html(200, html)
            return

        if self.path == "/health":
            self._send_json(200, {
                "ok": True,
                "service": "esi-vpn-enroll",
                "listen": f"{LISTEN_HOST}:{LISTEN_PORT}",
                "tls": TLS_ENABLED,
            })
            return

        if self.path.startswith("/enroll"):
            self._send_json(405, {"ok": False, "error": "method_not_allowed"})
            return

        self.send_error(404)

    def do_POST(self):
        if self.path != "/enroll":
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
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

        accepted, role, detail, error = run_radius(username, password)
        if error:
            log_event({
                "user": username,
                "role": role or "none",
                "accepted": False,
                "radius_result": "error",
                "error": error,
            })
            self._send_json(503, {"ok": False, "error": error})
            return
        state = load_state()
        if accepted and role == "vpn-student":
            address = allocate_ip(state, peer_key)
            if not address:
                self._send_json(503, {"ok": False, "error": "ip_pool_exhausted"})
                return
            if not add_peer(peer_key, address):
                self._send_json(503, {"ok": False, "error": "wg_peer_failed"})
                return
            state[peer_key] = {"user": username, "ip": address}
            if not save_state(state):
                self._send_json(503, {"ok": False, "error": "state_save_failed"})
                return
            pubkey = server_pubkey()
            if not pubkey:
                self._send_json(503, {"ok": False, "error": "server_key_missing"})
                return
            response = {
                "ok": True,
                "address": f"{address}/32",
                "endpoint": "198.51.100.20:51820",
                "server_pubkey": pubkey,
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

        self._send_json(status, response)

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
