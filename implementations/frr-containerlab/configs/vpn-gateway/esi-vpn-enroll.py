#!/usr/bin/env python3
import ipaddress
import json
import html
import os
import re
import ssl
import subprocess
import threading
import time
import urllib.parse
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RADIUS_HOST = os.environ.get("ESI_RADIUS_HOST", "192.168.50.80")
RADIUS_PORT = int(os.environ.get("ESI_RADIUS_PORT", "1812"))
RADIUS_SECRET = os.environ.get("ESI_RADIUS_SECRET", "EsiVpnRadius#2026")
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
LOGO_PATH = os.environ.get("ESI_VPN_LOGO", "/opt/esi/logo_esi.png")
CLIENT_AGENT_PORT = int(os.environ.get("ESI_VPN_CLIENT_AGENT_PORT", "15814"))
CLIENT_AGENT_ENABLED = os.environ.get("ESI_VPN_CLIENT_AGENT", "1") == "1"
VPN_ALLOWED_IPS = [
    item.strip()
    for item in os.environ.get(
        "ESI_VPN_ALLOWED_IPS",
        "192.168.50.30/32,192.168.10.10/32,192.168.70.10/32,192.168.70.30/32,198.51.100.30/32",
    ).split(",")
    if item.strip()
]

POOL_START = os.environ.get("ESI_VPN_POOL_START", "10.250.200.10")
POOL_END = os.environ.get("ESI_VPN_POOL_END", "10.250.200.200")

ROLE_PATTERN = re.compile(r"Filter-Id\s*=\s*\"?([A-Za-z0-9_-]+)\"?")
MAX_BODY_BYTES = int(os.environ.get("ESI_VPN_MAX_BODY", "8192"))
STATE_LOCK = threading.Lock()

PORTAL_CSS = """
    :root {
      color-scheme: light;
      --ink: #17202a;
      --muted: #607080;
      --line: #d9e1e8;
      --blue: #063f7d;
      --cyan: #00a0c8;
      --green: #0f7b43;
      --red: #b42335;
      --paper: #ffffff;
      --field: #f7fafc;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--ink);
      font-family: Inter, Arial, Helvetica, sans-serif;
      background:
        linear-gradient(120deg, rgba(6,63,125,.94), rgba(0,160,200,.72)),
        #0b1f36;
      display: grid;
      place-items: center;
      padding: 28px 14px;
    }
    main {
      width: min(980px, 100%);
      display: grid;
      grid-template-columns: minmax(280px, .85fr) minmax(320px, 1.15fr);
      background: var(--paper);
      box-shadow: 0 24px 70px rgba(0,0,0,.28);
      border: 1px solid rgba(255,255,255,.45);
      min-height: 620px;
    }
    .brand {
      color: #fff;
      background:
        linear-gradient(180deg, rgba(6,63,125,.92), rgba(6,63,125,.78)),
        #063f7d;
      padding: 34px 30px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }
    .brand img {
      width: 92px;
      height: 92px;
      object-fit: contain;
      border-radius: 50%;
      background: #fff;
      padding: 6px;
      border: 3px solid rgba(255,255,255,.7);
    }
    .brand h1 { margin: 28px 0 10px; font-size: 2rem; line-height: 1.05; }
    .brand p { margin: 0; line-height: 1.55; color: rgba(255,255,255,.86); }
    .panel { padding: 34px 36px; }
    .status {
      display: inline-block;
      margin-bottom: 16px;
      border-radius: 999px;
      padding: 6px 11px;
      font-size: .77rem;
      font-weight: 800;
      letter-spacing: .04em;
      text-transform: uppercase;
    }
    .ok { color: var(--green); background: #e8f6ef; }
    .bad { color: var(--red); background: #fdecee; }
    h2 { margin: 0 0 8px; font-size: 1.55rem; }
    .hint { margin: 0 0 18px; color: var(--muted); line-height: 1.5; }
    label { display: block; margin: 14px 0 6px; font-weight: 750; font-size: .88rem; }
    input, textarea {
      width: 100%;
      border: 1px solid var(--line);
      background: var(--field);
      border-radius: 7px;
      padding: 11px 12px;
      font: inherit;
      color: var(--ink);
    }
    textarea { min-height: 76px; resize: vertical; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .86rem; }
    .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 16px; }
    button {
      border: 0;
      border-radius: 7px;
      padding: 12px 14px;
      font: inherit;
      font-weight: 800;
      cursor: pointer;
      background: var(--blue);
      color: #fff;
    }
    button.secondary { background: #eef4f8; color: var(--blue); border: 1px solid var(--line); }
    pre {
      white-space: pre-wrap;
      word-break: break-word;
      background: #0d1b2a;
      color: #e7f7ff;
      padding: 16px;
      border-radius: 7px;
      overflow: auto;
      font-size: .86rem;
    }
    .demo { margin-top: 16px; padding: 12px; border: 1px solid var(--line); background: #fbfdff; font-size: .88rem; line-height: 1.45; }
    a { color: var(--blue); font-weight: 800; text-decoration: none; }
    a:hover { text-decoration: underline; }
    @media (max-width: 760px) {
      main { grid-template-columns: 1fr; }
      .brand { gap: 24px; }
      .panel { padding: 26px 22px; }
    }
"""


def render_shell(panel_html):
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ESI VPN Platform</title>
  <style>{PORTAL_CSS}</style>
</head>
<body>
  <main>
    <section class="brand">
      <div>
        <img src="/logo.png" alt="ESI logo">
        <h1>ESI VPN Platform</h1>
        <p>Remote access enrollment for lab users with WireGuard, RADIUS identity checks, and role-based internal reachability.</p>
      </div>
      <p>SquareOne operations profile - demo fabric gateway 198.51.100.20</p>
    </section>
    <section class="panel">{panel_html}</section>
  </main>
</body>
</html>
"""


def render_home_page():
    return render_shell("""
      <span class="status ok">Enrollment portal</span>
      <h2>Create a VPN lease</h2>
      <p class="hint">Use an ESI identity. A lab WireGuard keypair is generated automatically during enrollment unless you provide an existing public key.</p>
      <form method="post" action="/enroll" id="enroll-form">
        <label for="username">ESI identity</label>
        <input id="username" name="username" autocomplete="username" placeholder="amine.kadri@esi.dz" required>
        <label for="password">Password</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <input id="private_key" name="private_key" type="hidden">
        <label for="public_key">WireGuard public key (optional)</label>
        <textarea id="public_key" name="public_key" placeholder="Leave empty to generate a lab keypair"></textarea>
        <div class="actions">
          <button type="submit">Enroll</button>
          <button type="button" class="secondary" id="generate-key">Generate key now</button>
        </div>
      </form>
      <div class="demo"><strong>Student VPN demo</strong><br>tati.youcef@esi.dz / TatiLab#2026<br><strong>Professor same privilege</strong><br>hamani.nacer@esi.dz / HamaniTPs#2026</div>
      <pre id="generated-key" aria-live="polite"></pre>
      <script>
        const output = document.getElementById("generated-key");
        const publicKey = document.getElementById("public_key");
        const privateKey = document.getElementById("private_key");

        async function generateKeyPair() {
          output.textContent = "Generating WireGuard keypair...";
          const response = await fetch("/generate-key", { method: "POST", cache: "no-store" });
          const payload = await response.json();
          if (!payload.ok) {
            throw new Error(payload.error || "key generation failed");
          }
          privateKey.value = payload.private_key;
          publicKey.value = payload.public_key;
          output.textContent = "PrivateKey = " + payload.private_key + "\\nPublicKey = " + payload.public_key;
        }

        document.getElementById("generate-key").addEventListener("click", async () => {
          try {
            await generateKeyPair();
          } catch (error) {
            output.textContent = error.message || "key generation request failed";
          }
        });
      </script>
    """)


def render_logout_page():
    return render_shell("""
      <span class="status ok">VPN logout</span>
      <h2>Remove a VPN lease</h2>
      <p class="hint">Submit the WireGuard public key, or authenticate an ESI identity to remove that user's active lab leases.</p>
      <form method="post" action="/logout">
        <label for="public_key">WireGuard public key</label>
        <textarea id="public_key" name="public_key" placeholder="Public key to remove"></textarea>
        <label for="username">ESI identity</label>
        <input id="username" name="username" autocomplete="username" placeholder="amine.kadri@esi.dz">
        <label for="password">Password</label>
        <input id="password" name="password" type="password" autocomplete="current-password">
        <div class="actions">
          <button type="submit">Log out VPN lease</button>
        </div>
      </form>
    """)


def render_result_page(ok, title, message, config=None, public_key="", client_installed=False, install_error=""):
    badge = "ok" if ok else "bad"
    safe_title = html.escape(title)
    safe_message = html.escape(message)
    config_html = f"<pre>{html.escape(config)}</pre>" if config else ""
    install_html = ""
    if ok and client_installed:
        install_html = '<p class="hint"><strong>Client tunnel installed.</strong> This browser container is now using the VPN path.</p>'
    elif ok and install_error:
        install_html = f'<p class="hint"><strong>Manual setup required.</strong> Client auto-install failed: {html.escape(install_error)}</p>'
    logout_html = ""
    if ok and public_key:
        logout_html = f"""
      <form method="post" action="/logout">
        <input type="hidden" name="public_key" value="{html.escape(public_key)}">
        <button type="submit" class="secondary">Log out VPN lease</button>
      </form>
        """
    return render_shell(f"""
      <span class="status {badge}">{safe_title}</span>
      <h2>{safe_title}</h2>
      <p class="hint">{safe_message}</p>
      {install_html}
      {config_html}
      <div class="actions"><a href="/">Return to enrollment</a> <a href="/logout">Logout</a> <a href="/health">Health check</a></div>
      {logout_html}
    """)


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
        tmp_file = f"{STATE_FILE}.tmp"
        with open(tmp_file, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, indent=2)
        os.replace(tmp_file, STATE_FILE)
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
    accepted = re.search(r"Received\s+Access-Accept\b", output) is not None
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
            check=True,
            timeout=4,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return False
    return True


def remove_peer(peer_key):
    try:
        subprocess.run(
            ["wg", "set", WG_INTERFACE, "peer", peer_key, "remove"],
            check=True,
            timeout=4,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return False
    return True


def restore_peers():
    state = load_state()
    restored = 0
    for peer_key, entry in list(state.items()):
        address = str(entry.get("ip", "")).strip()
        if not peer_key or not address:
            continue
        if add_peer(peer_key, address):
            restored += 1
    log_event({"event": "vpn_peers_restored", "count": restored})


def client_agent_url(client_ip, path):
    return f"http://{client_ip}:{CLIENT_AGENT_PORT}{path}"


def call_client_agent(client_ip, path, payload=None):
    if not CLIENT_AGENT_ENABLED or not client_ip:
        return False, "client_agent_disabled"
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        client_agent_url(client_ip, path),
        data=data,
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            body = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        return False, body.strip() or f"http_{exc.code}"
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        return False, str(exc)

    try:
        result = json.loads(body)
    except json.JSONDecodeError:
        return False, body.strip() or "invalid_client_agent_response"
    if result.get("ok") is True:
        return True, ""
    return False, str(result.get("error", "client_agent_rejected"))


def install_client_tunnel(client_ip, private_key, address, server_key):
    if not private_key:
        return False, "private_key_not_available"
    try:
        ipaddress.ip_address(client_ip)
    except ValueError:
        return False, "invalid_client_ip"
    payload = {
        "private_key": private_key,
        "address": address,
        "server_pubkey": server_key,
        "endpoint": "198.51.100.20:51820",
        "allowed_ips": VPN_ALLOWED_IPS,
        "dns": "192.168.50.30",
    }
    return call_client_agent(client_ip, "/connect", payload)


def disconnect_client_tunnel(client_ip):
    return call_client_agent(client_ip, "/disconnect", {})


def server_pubkey():
    try:
        with open(SERVER_PUB, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except FileNotFoundError:
        return ""


def generate_keypair():
    try:
        private_proc = subprocess.run(
            ["wg", "genkey"],
            text=True,
            capture_output=True,
            timeout=4,
            check=True,
        )
        private_key = private_proc.stdout.strip()
        public_proc = subprocess.run(
            ["wg", "pubkey"],
            input=private_key + "\n",
            text=True,
            capture_output=True,
            timeout=4,
            check=True,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return "", ""
    return private_key, public_proc.stdout.strip()


def config_text(private_key, address, server_key):
    return "\n".join([
        "[Interface]",
        f"PrivateKey = {private_key or '<client-private-key>'}",
        f"Address = {address}",
        "",
        "[Peer]",
        f"PublicKey = {server_key}",
        "Endpoint = 198.51.100.20:51820",
        "AllowedIPs = " + ",".join(VPN_ALLOWED_IPS),
        "DNS = 192.168.50.30",
        "PersistentKeepalive = 25",
    ])


class Handler(BaseHTTPRequestHandler):
    server_version = "ESIVPNEnrollment/1.0"

    def setup(self):
        super().setup()
        self.request.settimeout(15)

    def _send_logo(self):
        try:
            with open(LOGO_PATH, "rb") as handle:
                body = handle.read()
        except OSError:
            body = b"<svg xmlns='http://www.w3.org/2000/svg' width='92' height='92'><rect width='92' height='92' fill='white'/><text x='46' y='55' text-anchor='middle' font-size='28' font-family='Arial' fill='#063f7d' font-weight='700'>ESI</text></svg>"
            content_type = "image/svg+xml"
        else:
            content_type = "image/png"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "public, max-age=3600")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
        if self.path == "/logo.png":
            self._send_logo()
            return
        if self.path in ("/", "/index.html"):
            self._send_html(200, render_home_page())
            return

        if self.path == "/logout":
            self._send_html(200, render_logout_page())
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

        if self.path.startswith("/logout"):
            self._send_json(405, {"ok": False, "error": "method_not_allowed"})
            return

        self.send_error(404)

    def do_POST(self):
        if self.path == "/generate-key":
            private_key, public_key = generate_keypair()
            if private_key and public_key:
                self._send_json(200, {"ok": True, "private_key": private_key, "public_key": public_key})
            else:
                self._send_json(503, {"ok": False, "error": "wireguard_keygen_failed"})
            return

        if self.path not in ("/enroll", "/logout"):
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if length < 0 or length > MAX_BODY_BYTES:
            self._send_json(413, {"ok": False, "error": "request_too_large"})
            return
        payload = self.rfile.read(length).decode("utf-8", "replace")
        content_type = self.headers.get("Content-Type", "")
        wants_json = "application/json" in content_type or "application/json" in self.headers.get("Accept", "")
        if "application/json" in content_type:
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                self._send_json(400, {"ok": False, "error": "invalid_json"})
                return
        else:
            parsed = urllib.parse.parse_qs(payload)
            data = {key: values[0] for key, values in parsed.items() if values}

        if self.path == "/logout":
            peer_key = str(data.get("public_key", "")).strip()
            username = str(data.get("username", "")).strip()
            password = str(data.get("password", "")).strip()
            removed = []
            with STATE_LOCK:
                state = load_state()

                if peer_key:
                    if peer_key in state:
                        entry = state[peer_key]
                        if remove_peer(peer_key):
                            removed.append({"public_key": peer_key, "ip": entry.get("ip", "")})
                        if entry.get("client_installed") and entry.get("client_ip"):
                            disconnect_client_tunnel(entry.get("client_ip", ""))
                        state.pop(peer_key, None)
                    else:
                        remove_peer(peer_key)
                elif username and password:
                    pass
                else:
                    if wants_json:
                        self._send_json(400, {"ok": False, "error": "missing_logout_identity"})
                    else:
                        self._send_html(400, render_result_page(False, "Missing logout identity", "Provide a public key or ESI credentials."))
                    return

            if not peer_key and username and password:
                accepted, role, detail, error = run_radius(username, password)
                if error:
                    if wants_json:
                        self._send_json(503, {"ok": False, "error": error})
                    else:
                        self._send_html(503, render_result_page(False, "Logout unavailable", f"RADIUS returned {error}."))
                    return
                if not accepted or role != "vpn-student":
                    if wants_json:
                        self._send_json(403, {"ok": False, "error": "identity_not_allowed", "role": role or "unknown"})
                    else:
                        self._send_html(403, render_result_page(False, "Logout denied", "The identity was not accepted for VPN lease management."))
                    return
                with STATE_LOCK:
                    state = load_state()
                    for key, entry in list(state.items()):
                        if entry.get("user") == username:
                            if remove_peer(key):
                                removed.append({"public_key": key, "ip": entry.get("ip", "")})
                            if entry.get("client_installed") and entry.get("client_ip"):
                                disconnect_client_tunnel(entry.get("client_ip", ""))
                            state.pop(key, None)

            with STATE_LOCK:
                save_state(state)
            log_event({"event": "vpn_logout", "user": username or "", "removed": len(removed)})
            if wants_json:
                self._send_json(200, {"ok": True, "removed": removed})
            else:
                self._send_html(200, render_result_page(True, "VPN lease removed", f"Removed {len(removed)} active lease(s)."))
            return

        username = str(data.get("username", "")).strip()
        password = str(data.get("password", "")).strip()
        peer_key = str(data.get("public_key", "")).strip()
        private_key = str(data.get("private_key", "")).strip()
        generated_key = False
        if not username or not password:
            if wants_json:
                self._send_json(400, {"ok": False, "error": "missing_fields"})
            else:
                self._send_html(400, render_result_page(False, "Missing fields", "Please provide an ESI identity and password."))
            return

        if not peer_key:
            private_key, peer_key = generate_keypair()
            generated_key = True
        if not peer_key:
            if wants_json:
                self._send_json(503, {"ok": False, "error": "wireguard_keygen_failed"})
            else:
                self._send_html(503, render_result_page(False, "Key generation failed", "The gateway could not generate a WireGuard keypair."))
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
            if wants_json:
                self._send_json(503, {"ok": False, "error": error})
            else:
                self._send_html(503, render_result_page(False, "Enrollment unavailable", f"RADIUS returned {error}."))
            return
        if accepted and role == "vpn-student":
            with STATE_LOCK:
                state = load_state()
                address = allocate_ip(state, peer_key)
                if not address:
                    self._send_json(503, {"ok": False, "error": "ip_pool_exhausted"})
                    return
                if not add_peer(peer_key, address):
                    self._send_json(503, {"ok": False, "error": "wg_peer_failed"})
                    return
                pubkey = server_pubkey()
                if not pubkey:
                    self._send_json(503, {"ok": False, "error": "server_key_missing"})
                    return
                client_installed = False
                client_install_error = ""
                if private_key:
                    client_installed, client_install_error = install_client_tunnel(
                        self.client_address[0],
                        private_key,
                        f"{address}/32",
                        pubkey,
                    )
                state[peer_key] = {
                    "user": username,
                    "ip": address,
                    "client_ip": self.client_address[0],
                    "client_installed": client_installed,
                }
                if not save_state(state):
                    self._send_json(503, {"ok": False, "error": "state_save_failed"})
                    return
            response = {
                "ok": True,
                "address": f"{address}/32",
                "endpoint": "198.51.100.20:51820",
                "server_pubkey": pubkey,
                "allowed_ips": VPN_ALLOWED_IPS,
                "dns": "192.168.50.30",
                "client_public_key": peer_key,
                "generated_key": generated_key,
                "client_installed": client_installed,
            }
            if client_install_error:
                response["client_install_error"] = client_install_error
            if private_key:
                response["client_private_key"] = private_key
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

        if wants_json:
            self._send_json(status, response)
            return

        if status == 200:
            config = config_text(private_key, response["address"], response["server_pubkey"])
            self._send_html(200, render_result_page(
                True,
                "Enrollment accepted",
                f"{username} received a WireGuard address {response['address']}.",
                config=config,
                public_key=peer_key,
                client_installed=response.get("client_installed", False),
                install_error=response.get("client_install_error", ""),
            ))
        else:
            self._send_html(403, render_result_page(
                False,
                "Enrollment denied",
                f"{username} is not in the VPN student role. Returned role: {response.get('role', 'unknown')}.",
            ))

    def log_message(self, fmt, *args):
        return


class EnrollmentServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, server_address, request_handler, tls_context=None):
        self.tls_context = tls_context
        super().__init__(server_address, request_handler)

    def get_request(self):
        while True:
            sock, addr = self.socket.accept()
            sock.settimeout(10)
            if not self.tls_context:
                return sock, addr
            try:
                tls_sock = self.tls_context.wrap_socket(
                    sock,
                    server_side=True,
                    do_handshake_on_connect=False,
                )
                tls_sock.settimeout(10)
                return tls_sock, addr
            except (OSError, ssl.SSLError, TimeoutError) as exc:
                log_event({"event": "tls_handshake_failed", "client": addr[0], "error": str(exc)})
                try:
                    sock.close()
                except OSError:
                    pass


def main():
    context = None
    if TLS_ENABLED:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(TLS_CERT, TLS_KEY)
    restore_peers()
    server = EnrollmentServer((LISTEN_HOST, LISTEN_PORT), Handler, tls_context=context)
    log_event({"event": "vpn_enroll_start", "listen": f"{LISTEN_HOST}:{LISTEN_PORT}", "tls": TLS_ENABLED})
    server.serve_forever()


if __name__ == "__main__":
    main()
