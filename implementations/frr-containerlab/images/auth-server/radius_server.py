#!/usr/bin/env python3
import hashlib
import json
import os
import re
import socketserver
import struct
import threading
from datetime import datetime, timezone

from ldap3 import Connection, Server, SUBTREE
from ldap3.core.exceptions import LDAPException
from ldap3.utils.conv import escape_filter_chars


ACCESS_REQUEST = 1
ACCESS_ACCEPT = 2
ACCESS_REJECT = 3

ATTR_USER_NAME = 1
ATTR_USER_PASSWORD = 2
ATTR_FILTER_ID = 11
ATTR_REPLY_MESSAGE = 18
ATTR_CALLING_STATION_ID = 31
ATTR_NAS_IDENTIFIER = 32

USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")

LDAP_URI = os.environ.get("LDAP_URI", "ldap://127.0.0.1:389")
LDAP_BASE_DN = os.environ.get("LDAP_BASE_DN", "dc=esi,dc=internal")
LDAP_BIND_DN = os.environ.get("LDAP_BIND_DN", f"cn=admin,{LDAP_BASE_DN}")
LDAP_BIND_PASSWORD = os.environ.get("LDAP_BIND_PASSWORD", "DirectoryAdmin@2026")
LOG_FILE = os.environ.get("ESI_RADIUS_LOG", "/var/log/esi-radius.log")

CLIENTS_RAW = os.environ.get(
    "ESI_RADIUS_CLIENTS",
    "10.200.0.2:CampusRadiusSecret@2026:campus-nac,198.51.100.20:VpnRadiusSecret@2026:vpn-gateway",
)


class LogState:
    lock = threading.Lock()


def log_event(event):
    event = dict(event)
    event["ts"] = datetime.now(timezone.utc).isoformat()
    with LogState.lock:
        with open(LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")


def parse_clients(raw):
    clients = {}
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        parts = item.split(":", 2)
        if len(parts) != 3:
            continue
        ip, secret, name = parts
        clients[ip.strip()] = {
            "secret": secret.strip(),
            "name": name.strip(),
        }
    return clients


CLIENTS = parse_clients(CLIENTS_RAW)


class Directory:
    def __init__(self):
        self.server = Server(LDAP_URI)

    def bind_admin(self):
        return Connection(
            self.server,
            user=LDAP_BIND_DN,
            password=LDAP_BIND_PASSWORD,
            auto_bind=True,
            receive_timeout=4,
        )

    def find_user(self, username):
        if not USERNAME_RE.fullmatch(username):
            return None
        try:
            conn = self.bind_admin()
            conn.search(
                search_base=LDAP_BASE_DN,
                search_filter=f"(uid={escape_filter_chars(username)})",
                search_scope=SUBTREE,
                attributes=["description"],
            )
            if not conn.entries:
                conn.unbind()
                return None
            entry = conn.entries[0]
            dn = str(entry.entry_dn)
            description = str(entry.description) if hasattr(entry, "description") else ""
            conn.unbind()
            return {"dn": dn, "description": description}
        except LDAPException:
            return None

    def authenticate(self, username, password):
        if not password:
            return False, [], "", "empty_password"
        user = self.find_user(username)
        if not user:
            return False, [], "", "unknown_user"
        try:
            conn = Connection(
                self.server,
                user=user["dn"],
                password=password,
                auto_bind=True,
                receive_timeout=4,
            )
            conn.unbind()
        except LDAPException:
            return False, [], user.get("description", ""), "ldap_bind_failed"
        groups = self.groups_for(username)
        return True, groups, user.get("description", ""), "ldap_bind_ok"

    def groups_for(self, username):
        if not USERNAME_RE.fullmatch(username):
            return []
        try:
            conn = self.bind_admin()
            conn.search(
                search_base=f"ou=Groups,{LDAP_BASE_DN}",
                search_filter=f"(memberUid={escape_filter_chars(username)})",
                search_scope=SUBTREE,
                attributes=["cn"],
            )
            groups = sorted(
                str(entry.cn)
                for entry in conn.entries
                if hasattr(entry, "cn")
            )
            conn.unbind()
            return groups
        except LDAPException:
            return []


def parse_attributes(data):
    attrs = []
    offset = 0
    while offset + 2 <= len(data):
        attr_type = data[offset]
        attr_len = data[offset + 1]
        if attr_len < 2 or offset + attr_len > len(data):
            break
        value = data[offset + 2 : offset + attr_len]
        attrs.append((attr_type, value))
        offset += attr_len
    return attrs


def encode_attribute(attr_type, value):
    if isinstance(value, str):
        value = value.encode("utf-8")
    length = len(value) + 2
    return bytes([attr_type, length]) + value


def decrypt_password(encrypted, secret, request_auth):
    if not encrypted or len(encrypted) % 16 != 0:
        return ""
    secret_bytes = secret.encode("utf-8")
    result = b""
    prev = request_auth
    for idx in range(0, len(encrypted), 16):
        block = encrypted[idx : idx + 16]
        digest = hashlib.md5(secret_bytes + prev).digest()
        result += bytes(a ^ b for a, b in zip(block, digest))
        prev = block
    return result.rstrip(b"\x00").decode("utf-8", "replace")


def response_authenticator(code, identifier, req_auth, attrs, secret):
    length = 20 + len(attrs)
    header = struct.pack("!BBH", code, identifier, length) + req_auth
    return hashlib.md5(header + attrs + secret.encode("utf-8")).digest()


def pick_role(nas_id, client_name, description, groups):
    context = nas_id or client_name
    if context == "campus-nac":
        if description == "campus-student-device":
            return "campus-student"
        if description == "campus-admin-device":
            return "campus-admin"
        return ""
    if context == "vpn-gateway":
        if description == "vpn-student" or "students" in groups:
            return "vpn-student"
        return ""
    return ""


class RadiusHandler(socketserver.BaseRequestHandler):
    directory = Directory()

    def handle(self):
        data, sock = self.request
        if len(data) < 20:
            return

        code, identifier, length = struct.unpack("!BBH", data[:4])
        request_auth = data[4:20]
        if length != len(data) or code != ACCESS_REQUEST:
            return

        client_ip = self.client_address[0]
        client = CLIENTS.get(client_ip)
        if not client:
            log_event({"phase": "request", "client": client_ip, "ok": False, "reason": "unknown_client"})
            return

        attrs = parse_attributes(data[20:])
        values = {}
        for attr_type, value in attrs:
            values.setdefault(attr_type, []).append(value)

        username = b"".join(values.get(ATTR_USER_NAME, [b""])).decode("utf-8", "replace")
        nas_id = b"".join(values.get(ATTR_NAS_IDENTIFIER, [b""])).decode("utf-8", "replace")
        calling_station = b"".join(values.get(ATTR_CALLING_STATION_ID, [b""])).decode("utf-8", "replace")
        encrypted = b"".join(values.get(ATTR_USER_PASSWORD, [b""]))
        password = decrypt_password(encrypted, client["secret"], request_auth)

        ok, groups, description, reason = self.directory.authenticate(username, password)
        role = pick_role(nas_id, client["name"], description, groups) if ok else ""

        if ok and role:
            reply_attrs = encode_attribute(ATTR_FILTER_ID, role)
            reply_code = ACCESS_ACCEPT
            reply_reason = "access_accept"
        else:
            reply_attrs = encode_attribute(ATTR_REPLY_MESSAGE, "access_reject")
            reply_code = ACCESS_REJECT
            reply_reason = "access_reject"

        auth = response_authenticator(reply_code, identifier, request_auth, reply_attrs, client["secret"])
        reply = struct.pack("!BBH", reply_code, identifier, 20 + len(reply_attrs)) + auth + reply_attrs
        sock.sendto(reply, self.client_address)

        log_event({
            "phase": "access",
            "client": client_ip,
            "nas_id": nas_id,
            "calling_station": calling_station,
            "user": username,
            "ok": reply_code == ACCESS_ACCEPT,
            "role": role or "none",
            "reason": reason if ok else reply_reason,
            "groups": groups,
            "description": description,
        })


class RadiusServer(socketserver.ThreadingMixIn, socketserver.UDPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    bind = os.environ.get("ESI_RADIUS_BIND", "0.0.0.0")
    port = int(os.environ.get("ESI_RADIUS_PORT", "1812"))
    with RadiusServer((bind, port), RadiusHandler) as server:
        log_event({"event": "radius_start", "bind": f"{bind}:{port}"})
        server.serve_forever()


if __name__ == "__main__":
    main()
