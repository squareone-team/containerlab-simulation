#!/usr/bin/env python3
import json
import hashlib
import os
import re
import socketserver
import struct
import threading
from datetime import datetime, timezone

from ldap3 import Connection, Server, SUBTREE
from ldap3.core.exceptions import LDAPException
from ldap3.utils.conv import escape_filter_chars


AUTHEN = 1
AUTHOR = 2
UNENCRYPTED = 0x01

AUTHEN_LOGIN = 1
AUTHEN_TYPE_PAP = 2
AUTHEN_SERVICE_LOGIN = 1
AUTHEN_METHOD_TACACSPLUS = 6

AUTHEN_STATUS_PASS = 1
AUTHEN_STATUS_FAIL = 2
AUTHEN_STATUS_ERROR = 7

AUTHOR_STATUS_PASS_ADD = 1
AUTHOR_STATUS_FAIL = 0x10
AUTHOR_STATUS_ERROR = 0x11

USERNAME_RE = re.compile(r"^[A-Za-z0-9_.@-]{1,96}$")

LDAP_URI = os.environ.get("LDAP_URI", "ldap://127.0.0.1:389")
LDAP_BASE_DN = os.environ.get("LDAP_BASE_DN", "dc=esi,dc=internal")
LDAP_BIND_DN = os.environ.get("LDAP_BIND_DN", f"cn=admin,{LDAP_BASE_DN}")
LDAP_BIND_PASSWORD = os.environ.get("LDAP_BIND_PASSWORD", "EsiDirectoryRoot#2026")
TACACS_SECRET = os.environ.get("ESI_TACACS_SECRET", "SquareOneTacacs#2026").encode("utf-8")
ALLOW_UNENCRYPTED = os.environ.get("ESI_TACACS_ALLOW_UNENCRYPTED", "0") == "1"
SEND_UNENCRYPTED = os.environ.get("ESI_TACACS_SEND_UNENCRYPTED", "0") == "1"
LOG_FILE = os.environ.get("ESI_TACACS_LOG", "/var/log/esi-tacacs.log")

RESOURCE_RULES = {
    "admins": {"student", "hpc", "admin", "core"},
    "squareone-admins": {"student", "hpc", "admin", "core"},
    "students": {"student", "hpc"},
    "student": {"student", "hpc"},
    "hpc-users": {"hpc"},
}


def log_event(event):
    event = dict(event)
    event["ts"] = datetime.now(timezone.utc).isoformat()
    line = json.dumps(event, sort_keys=True)
    with LogState.lock:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


class LogState:
    lock = threading.Lock()


class Directory:
    def __init__(self):
        self.server = Server(LDAP_URI)

    def user_dn(self, username):
        if not USERNAME_RE.fullmatch(username):
            return None
        return f"uid={username},ou=People,{LDAP_BASE_DN}"

    def bind_admin(self):
        return Connection(
            self.server,
            user=LDAP_BIND_DN,
            password=LDAP_BIND_PASSWORD,
            auto_bind=True,
            receive_timeout=4,
        )

    def authenticate(self, username, password):
        dn = self.user_dn(username)
        if not dn:
            return False, [], "invalid_username"
        if not password:
            return False, [], "empty_password"
        try:
            conn = Connection(
                self.server,
                user=dn,
                password=password,
                auto_bind=True,
                receive_timeout=4,
            )
            conn.unbind()
        except LDAPException:
            return False, [], "ldap_bind_failed"

        groups = self.groups_for(username)
        return True, groups, "ldap_bind_ok"

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


def recv_exact(sock, length):
    chunks = []
    remaining = length
    while remaining:
        data = sock.recv(remaining)
        if not data:
            raise EOFError("short read")
        chunks.append(data)
        remaining -= len(data)
    return b"".join(chunks)


def to_text(data):
    return data.decode("utf-8", "replace")


def tacacs_crypt(body, version, seq_no, session_id):
    if not TACACS_SECRET:
        return body
    seed = struct.pack("!I", session_id) + TACACS_SECRET + bytes([version, seq_no])
    pad = b""
    previous = b""
    while len(pad) < len(body):
        previous = hashlib.md5(seed + previous).digest()
        pad += previous
    return bytes(value ^ pad_byte for value, pad_byte in zip(body, pad))


def parse_authen_start(body):
    if len(body) < 8:
        raise ValueError("authen body too short")
    action, priv_lvl, authen_type, service, ulen, plen, rlen, dlen = body[:8]
    offset = 8
    expected = offset + ulen + plen + rlen + dlen
    if len(body) != expected:
        raise ValueError("authen length mismatch")
    user = to_text(body[offset:offset + ulen])
    offset += ulen
    port = to_text(body[offset:offset + plen])
    offset += plen
    rem_addr = to_text(body[offset:offset + rlen])
    offset += rlen
    password = to_text(body[offset:offset + dlen])
    return {
        "action": action,
        "priv_lvl": priv_lvl,
        "authen_type": authen_type,
        "service": service,
        "user": user,
        "port": port,
        "rem_addr": rem_addr,
        "password": password,
    }


def parse_author_request(body):
    if len(body) < 8:
        raise ValueError("author body too short")
    method, priv_lvl, authen_type, service, ulen, plen, rlen, arg_cnt = body[:8]
    offset = 8
    names_end = offset + ulen + plen + rlen
    if len(body) < names_end + arg_cnt:
        raise ValueError("author length mismatch")
    user = to_text(body[offset:offset + ulen])
    offset += ulen
    port = to_text(body[offset:offset + plen])
    offset += plen
    rem_addr = to_text(body[offset:offset + rlen])
    offset += rlen
    arg_lengths = list(body[offset:offset + arg_cnt])
    offset += arg_cnt
    args = []
    for arg_len in arg_lengths:
        if len(body) < offset + arg_len:
            raise ValueError("author arg length mismatch")
        args.append(to_text(body[offset:offset + arg_len]))
        offset += arg_len
    if offset != len(body):
        raise ValueError("author trailing data")
    return {
        "method": method,
        "priv_lvl": priv_lvl,
        "authen_type": authen_type,
        "service": service,
        "user": user,
        "port": port,
        "rem_addr": rem_addr,
        "args": args,
    }


def resource_from_args(args):
    for arg in args:
        key, sep, value = arg.partition("=")
        if sep and key == "resource":
            return value
    return "unknown"


def authorization_decision(groups, resource):
    allowed = set()
    for group in groups:
        allowed.update(RESOURCE_RULES.get(group, set()))
    if resource in allowed:
        return True, "authorized"
    if not groups:
        return False, "no_ldap_groups"
    return False, "resource_not_allowed"


def authen_reply(status, message, data=b""):
    msg = message.encode("utf-8")
    return struct.pack("!BBHH", status, 0, len(msg), len(data)) + msg + data


def author_reply(status, message, args=None, data=b""):
    args = args or []
    encoded_args = [arg.encode("utf-8") for arg in args]
    msg = message.encode("utf-8")
    lengths = bytes(len(arg) for arg in encoded_args)
    return (
        struct.pack("!BBHH", status, len(encoded_args), len(msg), len(data))
        + lengths
        + msg
        + data
        + b"".join(encoded_args)
    )


class TacacsHandler(socketserver.BaseRequestHandler):
    def reply(self, version, pkt_type, seq_no, session_id, body):
        reply_seq = seq_no + 1
        if SEND_UNENCRYPTED:
            flags = UNENCRYPTED
            wire_body = body
        else:
            flags = 0
            wire_body = tacacs_crypt(body, version, reply_seq, session_id)
        header = struct.pack("!BBBBII", version, pkt_type, reply_seq, flags, session_id, len(body))
        self.request.sendall(header + wire_body)

    def handle_authen(self, version, seq_no, session_id, body):
        try:
            req = parse_authen_start(body)
            if (
                req["action"] != AUTHEN_LOGIN
                or req["authen_type"] != AUTHEN_TYPE_PAP
                or req["service"] != AUTHEN_SERVICE_LOGIN
            ):
                status, reason, groups = AUTHEN_STATUS_FAIL, "unsupported_authen_type", []
            else:
                ok, groups, reason = self.server.directory.authenticate(req["user"], req["password"])
                status = AUTHEN_STATUS_PASS if ok else AUTHEN_STATUS_FAIL

            log_event({
                "phase": "authentication",
                "client": self.client_address[0],
                "user": req.get("user", ""),
                "rhost": req.get("rem_addr", ""),
                "ok": status == AUTHEN_STATUS_PASS,
                "reason": reason,
                "groups": groups,
            })
            self.reply(version, AUTHEN, seq_no, session_id, authen_reply(status, reason))
        except Exception as exc:
            log_event({"phase": "authentication", "client": self.client_address[0], "ok": False, "reason": str(exc)})
            self.reply(version, AUTHEN, seq_no, session_id, authen_reply(AUTHEN_STATUS_ERROR, "server_error"))

    def handle_author(self, version, seq_no, session_id, body):
        try:
            req = parse_author_request(body)
            resource = resource_from_args(req["args"])
            groups = self.server.directory.groups_for(req["user"])
            ok, reason = authorization_decision(groups, resource)
            status = AUTHOR_STATUS_PASS_ADD if ok else AUTHOR_STATUS_FAIL
            reply_args = [f"resource={resource}", "service=ssh"]

            log_event({
                "phase": "authorization",
                "client": self.client_address[0],
                "user": req["user"],
                "resource": resource,
                "rhost": req["rem_addr"],
                "ok": ok,
                "reason": reason,
                "groups": groups,
            })
            self.reply(version, AUTHOR, seq_no, session_id, author_reply(status, reason, reply_args))
        except Exception as exc:
            log_event({"phase": "authorization", "client": self.client_address[0], "ok": False, "reason": str(exc)})
            self.reply(version, AUTHOR, seq_no, session_id, author_reply(AUTHOR_STATUS_ERROR, "server_error"))

    def handle(self):
        try:
            header = recv_exact(self.request, 12)
            version, pkt_type, seq_no, flags, session_id, length = struct.unpack("!BBBBII", header)
            wire_body = recv_exact(self.request, length)
            if flags & UNENCRYPTED:
                if not ALLOW_UNENCRYPTED:
                    if pkt_type == AUTHEN:
                        self.reply(version, pkt_type, seq_no, session_id, authen_reply(AUTHEN_STATUS_ERROR, "unencrypted_not_allowed"))
                    elif pkt_type == AUTHOR:
                        self.reply(version, pkt_type, seq_no, session_id, author_reply(AUTHOR_STATUS_ERROR, "unencrypted_not_allowed"))
                    return
                body = wire_body
            else:
                body = tacacs_crypt(wire_body, version, seq_no, session_id)
            if not (flags & UNENCRYPTED):
                log_event({
                    "phase": "transport",
                    "client": self.client_address[0],
                    "pkt_type": pkt_type,
                    "encrypted_body": True,
                })
            else:
                log_event({
                    "phase": "transport",
                    "client": self.client_address[0],
                    "pkt_type": pkt_type,
                    "encrypted_body": False,
                })
            if flags & UNENCRYPTED and not ALLOW_UNENCRYPTED:
                return
            if pkt_type == AUTHEN:
                self.handle_authen(version, seq_no, session_id, body)
            elif pkt_type == AUTHOR:
                self.handle_author(version, seq_no, session_id, body)
        except EOFError:
            return


class TacacsServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    bind = os.environ.get("ESI_TACACS_BIND", "0.0.0.0")
    port = int(os.environ.get("ESI_TACACS_PORT", "49"))
    with TacacsServer((bind, port), TacacsHandler) as server:
        server.directory = Directory()
        print(f"esi-tacacs listening on {bind}:{port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
