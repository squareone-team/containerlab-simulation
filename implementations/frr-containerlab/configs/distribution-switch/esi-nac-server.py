#!/usr/bin/env python3
import json
import html
import os
import re
import ssl
import subprocess
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RADIUS_HOST = os.environ.get("ESI_RADIUS_HOST", "192.168.50.80")
RADIUS_PORT = int(os.environ.get("ESI_RADIUS_PORT", "1812"))
RADIUS_SECRET = os.environ.get("ESI_RADIUS_SECRET", "EsiCampusNacRadius#2026")
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
LOGO_PATH = os.environ.get("ESI_NAC_LOGO", "/opt/esi/logo_esi.png")

ROLE_PATTERN = re.compile(r"Filter-Id\s*=\s*\"?([A-Za-z0-9_-]+)\"?")


PORTAL_CSS = """
    :root {
      color-scheme: light;
      --esi-blue: #055bb5;
      --esi-blue-dark: #034a92;
      --esi-red: #c7102e;
      --esi-gold: #f5a623;
      --ink: #24313f;
      --muted: #66727f;
      --line: #d7dbdd;
      --paper: #ffffff;
      --canvas: #f4f6f8;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background:
        linear-gradient(135deg, rgba(5,91,181,.06), rgba(199,16,46,.05)),
        var(--canvas);
      color: var(--ink);
      font-family: Arial, Helvetica, sans-serif;
    }
    .portal {
      width: min(430px, calc(100vw - 28px));
      border: 1px solid var(--line);
      box-shadow: 0 18px 45px rgba(20, 37, 55, .18);
      background: var(--paper);
    }
    .masthead {
      background: var(--esi-blue);
      color: #fff;
      text-align: center;
      padding: 20px 18px 18px;
      border-bottom: 3px solid var(--esi-red);
    }
    .logo {
      display: inline-grid;
      place-items: center;
      width: 58px;
      height: 58px;
      margin-bottom: 8px;
      border-radius: 50%;
      background: #fff;
      border: 3px solid rgba(255,255,255,.7);
      overflow: hidden;
    }
    .logo img { width: 100%; height: 100%; object-fit: contain; }
    .logo-fallback { color: var(--esi-blue); font-weight: 800; font-size: 1.15rem; }
    h1 { margin: 0; font-size: 1.55rem; font-weight: 700; text-shadow: 1px 2px 4px rgba(0,0,0,.25); }
    .body { padding: 24px 26px 22px; }
    .hint { margin: 0 0 16px; color: var(--muted); line-height: 1.45; font-size: .95rem; }
    label { display: block; margin: 14px 0 6px; font-size: .86rem; font-weight: 700; color: #4a5561; }
    input {
      width: 100%;
      padding: 11px 12px;
      border: 1px solid var(--esi-gold);
      border-radius: 6px;
      font: inherit;
      color: var(--ink);
      background: #fff;
    }
    input:focus { outline: 2px solid rgba(245,166,35,.25); border-color: var(--esi-gold); }
    button {
      width: 100%;
      margin-top: 18px;
      border: 0;
      border-radius: 4px;
      padding: 12px 14px;
      background: var(--esi-blue);
      color: #fff;
      font: inherit;
      font-weight: 700;
      cursor: pointer;
    }
    button:hover { background: var(--esi-blue-dark); }
    .demo-grid { display: grid; gap: 8px; margin: 18px 0 4px; }
    .demo {
      border-left: 4px solid var(--esi-gold);
      background: #fbfbfd;
      padding: 10px 12px;
      font-size: .86rem;
      line-height: 1.35;
    }
    .demo strong { display: block; color: var(--ink); margin-bottom: 2px; }
    .links { display: grid; gap: 9px; margin-top: 18px; }
    a { color: var(--esi-blue); font-weight: 700; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .status {
      display: inline-block;
      margin-bottom: 14px;
      border-radius: 999px;
      padding: 6px 11px;
      font-size: .78rem;
      font-weight: 800;
      letter-spacing: .03em;
      text-transform: uppercase;
    }
    .ok { background: #e6f6ed; color: #0f6f3d; }
    .bad { background: #fdebed; color: #a50e26; }
    .warn { background: #fff5df; color: #8a5b00; }
    .foot { margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--line); color: var(--muted); font-size: .82rem; }
"""


def logo_markup():
    return '<span class="logo"><img src="/logo.png" alt="ESI"></span>'


def render_login_page():
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Sign in to access this network</title>
  <style>{PORTAL_CSS}</style>
</head>
<body>
  <main class="portal">
    <header class="masthead">
      {logo_markup()}
      <h1>Bienvenus au portail ESI</h1>
    </header>
    <section class="body">
      <p class="hint">Authentifiez votre session pour acceder au reseau pedagogique, a Moodle et aux services autorises.</p>
      <form method="post" action="/auth">
      <label for="username">Identifiant ESI</label>
      <input id="username" name="username" autocomplete="username" placeholder="prenom.nom@esi.dz" required>
      <label for="password">Password</label>
      <input id="password" name="password" type="password" autocomplete="current-password" required>
      <button type="submit">Sign in</button>
    </form>
    <div class="demo-grid" aria-label="Demo accounts">
      <div class="demo"><strong>Professor/student role</strong> hamani.nacer@esi.dz / HamaniTPs#2026</div>
      <div class="demo"><strong>Student role</strong> tati.youcef@esi.dz / TatiLab#2026</div>
      <div class="demo"><strong>SquareOne admin</strong> squareone.admin@esi.dz / SquareOneRoot#2026</div>
    </div>
    <div class="foot"><a href="http://portail.esi-lan.dz/password">Changer le mot de passe</a></div>
    </section>
  </main>
</body>
</html>
"""


def render_status_page(kind, title, message, role="", username=""):
    badge_class = {"ok": "ok", "bad": "bad", "warn": "warn"}.get(kind, "warn")
    safe_title = html.escape(title)
    safe_message = html.escape(message)
    safe_role = html.escape(role)
    safe_user = html.escape(username)
    links = ""
    if kind == "ok":
        links = """
        <div class="links">
          <a href="http://www.google.com/">www.google.com</a>
          <a href="http://moodle.esi.dz/">Moodle ESI</a>
          <a href="https://hpc-jupyter.esi.internal:8080/hub/login">JupyterHub</a>
          <a href="/logout">Sign out</a>
        </div>
        """
    else:
        links = '<div class="links"><a href="/">Try again</a></div>'
    details = ""
    if safe_role:
        details += f"<p class=\"hint\">Role: <strong>{safe_role}</strong></p>"
    if safe_user:
        details += f"<p class=\"hint\">Identity: <strong>{safe_user}</strong></p>"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{safe_title}</title>
  <style>{PORTAL_CSS}</style>
</head>
<body>
  <main class="portal">
    <header class="masthead">
      {logo_markup()}
      <h1>Bienvenus au portail ESI</h1>
    </header>
    <section class="body">
      <span class="status {badge_class}">{safe_title}</span>
      <p class="hint">{safe_message}</p>
      {details}
      {links}
    </section>
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
    accepted = re.search(r"Received\s+Access-Accept\b", output) is not None
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
    def send_logo(self):
        try:
            with open(LOGO_PATH, "rb") as handle:
                body = handle.read()
        except OSError:
            body = b"<svg xmlns='http://www.w3.org/2000/svg' width='80' height='80'><rect width='80' height='80' fill='white'/><text x='40' y='47' text-anchor='middle' font-size='24' font-family='Arial' fill='#055bb5' font-weight='700'>ESI</text></svg>"
            content_type = "image/svg+xml"
        else:
            content_type = "image/png"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "public, max-age=3600")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
        if self.path == "/logo.png":
            self.send_logo()
            return
        if self.path in ("/", "/login"):
            self.send_html(200, render_login_page())
            return
        if self.path.startswith("/logout"):
            clear_ip(self.client_address[0])
            log_event({"client": self.client_address[0], "event": "nac_logout"})
            self.send_html(200, render_status_page(
                "warn",
                "Signed out",
                "Your NAC session was removed from the campus gateway.",
            ))
            return
        if self.path.startswith("/granted"):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            role = query.get("role", ["authenticated"])[0]
            username = query.get("user", [""])[0]
            self.send_html(200, render_status_page(
                "ok",
                "Access granted",
                "Votre session est autorisee. Les services ci-dessous sont maintenant accessibles selon votre role.",
                role=role,
                username=username,
            ))
            return
        self.send_error(404)

    def do_POST(self):
        if self.path == "/logout":
            src_ip = self.client_address[0]
            wants_json = "application/json" in self.headers.get("Accept", "")
            clear_ip(src_ip)
            log_event({"client": src_ip, "event": "nac_logout"})
            if wants_json:
                self.send_json(200, {"ok": True, "ip": src_ip, "event": "logout"})
            else:
                self.send_html(200, render_status_page(
                    "warn",
                    "Signed out",
                    "Your NAC session was removed from the campus gateway.",
                ))
            return

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
            self.send_html(400, render_status_page(
                "bad",
                "Missing credentials",
                "Please enter both your ESI identity and password.",
            ))
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
            self.send_header(
                "Location",
                f"/granted?role={urllib.parse.quote(role)}&user={urllib.parse.quote(username)}",
            )
            self.end_headers()
            return
        self.send_html(403, render_status_page(
            "bad",
            "Access denied",
            "The identity was not accepted by RADIUS or has no role on this gateway.",
            role=role or "unknown",
            username=username,
        ))

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


class NACServer(ThreadingHTTPServer):
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
    server = NACServer((LISTEN_HOST, LISTEN_PORT), Handler, tls_context=context)
    if REDIRECT_PORT > 0:
        redirect = NACServer((LISTEN_HOST, REDIRECT_PORT), RedirectHandler)
        threading.Thread(target=redirect.serve_forever, daemon=True).start()
    log_event({"event": "nac_start", "listen": f"{LISTEN_HOST}:{LISTEN_PORT}", "redirect": REDIRECT_PORT, "tls": TLS_ENABLED})
    server.serve_forever()


if __name__ == "__main__":
    main()
