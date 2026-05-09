#!/usr/bin/env python3
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RADIUS_HOST = os.environ.get("ESI_RADIUS_HOST", "192.168.50.80")
RADIUS_PORT = int(os.environ.get("ESI_RADIUS_PORT", "1812"))
RADIUS_SECRET = os.environ.get("ESI_RADIUS_SECRET", "CampusRadiusSecret@2026")
RADIUS_NAS_ID = os.environ.get("ESI_RADIUS_NAS_ID", "campus-nac")

LISTEN_HOST = os.environ.get("ESI_NAC_LISTEN", "192.168.110.1")
LISTEN_PORT = int(os.environ.get("ESI_NAC_PORT", "8085"))

NAC_TABLE = os.environ.get("ESI_NAC_TABLE", "campus_nac")
STUDENT_SET = os.environ.get("ESI_NAC_STUDENT_SET", "campus_students")
ADMIN_SET = os.environ.get("ESI_NAC_ADMIN_SET", "campus_admins")
ENTRY_TTL = int(os.environ.get("ESI_NAC_TTL", "1800"))

LOG_FILE = os.environ.get("ESI_NAC_LOG", "/var/log/esi-nac.log")

ROLE_PATTERN = re.compile(r"Filter-Id\s*=\s*\"?([A-Za-z0-9_-]+)\"?")


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
    def do_POST(self):
        if self.path != "/auth":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length).decode("utf-8", "replace")
        src_ip = self.client_address[0]
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            self.send_error(400)
            return

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
            "detail": detail,
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
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    log_event({"event": "nac_start", "listen": f"{LISTEN_HOST}:{LISTEN_PORT}"})
    server.serve_forever()


if __name__ == "__main__":
    main()
