#!/usr/bin/env python3
import json
import os
import re
import ssl
import subprocess
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RADIUS_HOST = os.environ.get("ESI_RADIUS_HOST", "192.168.50.80")
RADIUS_PORT = int(os.environ.get("ESI_RADIUS_PORT", "1812"))
RADIUS_SECRET = os.environ.get("ESI_RADIUS_SECRET", "CampusRadiusSecret@2026")
RADIUS_NAS_ID = os.environ.get("ESI_RADIUS_NAS_ID", "campus-nac")

LISTEN_HOST = os.environ.get("ESI_NAC_LISTEN", "192.168.110.1")
LISTEN_PORT = int(os.environ.get("ESI_NAC_PORT", "8443"))
REDIRECT_PORT = int(os.environ.get("ESI_NAC_REDIRECT_PORT", "80"))
TLS_CERT = os.environ.get("ESI_NAC_TLS_CERT", "/etc/esi-nac/tls/nac.crt")
TLS_KEY = os.environ.get("ESI_NAC_TLS_KEY", "/etc/esi-nac/tls/nac.key")
TLS_ENABLED = os.environ.get("ESI_NAC_TLS", "1") == "1"

NAC_TABLE = os.environ.get("ESI_NAC_TABLE", "campus_nac")
STUDENT_SET = os.environ.get("ESI_NAC_STUDENT_SET", "campus_students")
ADMIN_SET = os.environ.get("ESI_NAC_ADMIN_SET", "campus_admins")
ENTRY_TTL = int(os.environ.get("ESI_NAC_TTL", "1800"))

LOG_FILE = os.environ.get("ESI_NAC_LOG", "/var/log/esi-nac.log")

ROLE_PATTERN = re.compile(r"Filter-Id\s*=\s*\"?([A-Za-z0-9_-]+)\"?")


LOGIN_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ESI Campus Access</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #eef3f7; color: #17202a; }
    main { width: min(420px, calc(100vw - 32px)); background: white; border: 1px solid #d8e0e8; border-radius: 8px; padding: 24px; box-shadow: 0 18px 48px rgba(23,32,42,.12); }
    h1 { margin: 0 0 8px; font-size: 1.45rem; }
    p { margin: 0 0 18px; color: #44515f; line-height: 1.45; }
    label { display: block; margin: 14px 0 6px; font-weight: 650; }
    input { width: 100%; box-sizing: border-box; padding: 11px 12px; border: 1px solid #aab6c2; border-radius: 6px; font: inherit; }
    button { width: 100%; margin-top: 18px; border: 0; border-radius: 6px; padding: 12px; background: #005f73; color: white; font: inherit; font-weight: 700; cursor: pointer; }
    .links { display: grid; gap: 8px; margin-top: 18px; }
    a { color: #005f73; font-weight: 650; }
    .note { font-size: .9rem; }
  </style>
</head>
<body>
  <main>
    <h1>ESI Campus Access</h1>
    <p>Authenticate this device before browsing the Internet or datacenter services.</p>
    <form method="post" action="/auth">
      <label for="username">Device identity</label>
      <input id="username" name="username" autocomplete="username" required>
      <label for="password">Password</label>
      <input id="password" name="password" type="password" autocomplete="current-password" required>
      <button type="submit">Sign in</button>
    </form>
    <p class="note">Student demo: dev-campus-student-01. Admin demo: dev-campus-admin-01.</p>
  </main>
</body>
</html>
"""


def log_event(event):
    event = dict(event)
    with open(LOG_FILE, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def run_radius(user, password, src_ip):
    payload = (
        f'User-Name = "{user}"\n'
        f'User-Password = "{password}"\n'
        f'NAS-Identifier = "{RADIUS_NAS_ID}"\n'
        f'Calling-Station-Id = "{src_ip}"\n'
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
            capture_output=True,
            timeout=6,
        )
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or "") + (exc.stderr or "")
        return False, "", (output.strip() or "radius_timeout")
    output = (proc.stdout or "") + (proc.stderr or "")
    accepted = "Access-Accept" in output
    role = ""
    match = ROLE_PATTERN.search(output)
    if match:
        role = match.group(1)
    return accepted, role, output.strip()


def nft_apply(command):
    subprocess.run(
        ["nft", "-f", "-"],
        input=command,
        text=True,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def clear_ip(ip_addr):
    nft_apply(f"delete element inet {NAC_TABLE} {STUDENT_SET} {{ {ip_addr} }}")
    nft_apply(f"delete element inet {NAC_TABLE} {ADMIN_SET} {{ {ip_addr} }}")


def assign_role(ip_addr, role):
    clear_ip(ip_addr)
    target_set = STUDENT_SET if role == "campus-student" else ADMIN_SET
    nft_apply(
        f"add element inet {NAC_TABLE} {target_set} {{ {ip_addr} timeout {ENTRY_TTL}s }}"
    )


class Handler(BaseHTTPRequestHandler):
    def send_html(self, status, html):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/login"):
            self.send_html(200, LOGIN_PAGE)
            return
        if self.path.startswith("/granted"):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            role = query.get("role", ["authenticated"])[0]
            self.send_html(200, f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Access Granted</title></head>
<body>
  <h1>Access granted</h1>
  <p>Role: <strong>{role}</strong></p>
  <ul>
    <li><a href="http://internet.esi.dz/">Internet test site</a></li>
    <li><a href="http://esi.dz/">ESI.dz DMZ portal</a></li>
    <li><a href="https://hpc-jupyter.esi.internal:8080/hub/login">JupyterHub</a></li>
  </ul>
</body>
</html>
""")
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/auth":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length).decode("utf-8", "replace")
        src_ip = self.client_address[0]
        content_type = self.headers.get("Content-Type", "")
        wants_json = "application/json" in content_type or "application/json" in self.headers.get("Accept", "")
        if "application/json" in content_type:
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                self.send_error(400)
                return
        else:
            parsed = urllib.parse.parse_qs(payload)
            data = {key: values[0] for key, values in parsed.items() if values}

        username = str(data.get("username", "")).strip()
        password = str(data.get("password", "")).strip()
        if not username or not password:
            self.send_error(400)
            return

        accepted, role, detail = run_radius(username, password, src_ip)
        if accepted and role in ("campus-student", "campus-admin"):
            assign_role(src_ip, role)
            response = {"ok": True, "role": role, "ip": src_ip}
            status = 200
        else:
            clear_ip(src_ip)
            response = {"ok": False, "role": role or "unknown", "ip": src_ip}
            status = 403

        log_event({
            "client": src_ip,
            "user": username,
            "accepted": accepted,
            "role": role or "none",
            "radius_result": "accepted" if accepted else "rejected",
        })

        if wants_json:
            self.send_json(status, response)
            return
        if status == 200:
            self.send_response(303)
            self.send_header("Location", f"/granted?role={urllib.parse.quote(role)}")
            self.end_headers()
            return
        self.send_html(403, "<!doctype html><title>Access denied</title><h1>Access denied</h1><p>Invalid device credentials.</p><p><a href=\"/\">Try again</a></p>")

    def log_message(self, fmt, *args):
        return


class RedirectHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(302)
        self.send_header("Location", f"https://{LISTEN_HOST}:{LISTEN_PORT}/")
        self.end_headers()

    def do_POST(self):
        self.send_error(400, "Use HTTPS")

    def log_message(self, fmt, *args):
        return


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    if REDIRECT_PORT > 0:
        redirect = ThreadingHTTPServer((LISTEN_HOST, REDIRECT_PORT), RedirectHandler)
        threading.Thread(target=redirect.serve_forever, daemon=True).start()
    if TLS_ENABLED:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(TLS_CERT, TLS_KEY)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    log_event({"event": "nac_start", "listen": f"{LISTEN_HOST}:{LISTEN_PORT}", "redirect": REDIRECT_PORT, "tls": TLS_ENABLED})
    server.serve_forever()


if __name__ == "__main__":
    main()
