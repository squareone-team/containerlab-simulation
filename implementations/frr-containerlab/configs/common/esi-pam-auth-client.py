#!/usr/bin/env python3
import json
import hashlib
import os
import random
import socket
import struct
import sys
from datetime import datetime, timezone


AUTHEN = 1
AUTHOR = 2
UNENCRYPTED = 0x01

AUTHEN_LOGIN = 1
AUTHEN_TYPE_PAP = 2
AUTHEN_SERVICE_LOGIN = 1
AUTHEN_METHOD_TACACSPLUS = 6

AUTHEN_STATUS_PASS = 1
AUTHOR_STATUS_PASS_ADD = 1
AUTHOR_STATUS_PASS_REPL = 2

TACACS_HOST = os.environ.get("ESI_TACACS_HOST", "192.168.50.80")
TACACS_PORT = int(os.environ.get("ESI_TACACS_PORT", "49"))
TACACS_SECRET = os.environ.get("ESI_TACACS_SECRET", "SquareOneTacacs#2026").encode("utf-8")
SEND_UNENCRYPTED = os.environ.get("ESI_TACACS_SEND_UNENCRYPTED", "0") == "1"
RESOURCE_FILE = os.environ.get("ESI_AUTH_RESOURCE_FILE", "/etc/esi-auth-resource")
LOG_FILE = os.environ.get("ESI_AUTH_CLIENT_LOG", "/var/log/esi-auth-client.log")


def read_resource():
    try:
        with open(RESOURCE_FILE, "r", encoding="utf-8") as fh:
            resource = fh.read().strip()
            return resource or "unknown"
    except FileNotFoundError:
        return "unknown"


def log_event(event):
    event = dict(event)
    event["ts"] = datetime.now(timezone.utc).isoformat()
    with open(LOG_FILE, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")


def recv_exact(sock, length):
    chunks = []
    remaining = length
    while remaining:
        data = sock.recv(remaining)
        if not data:
            raise EOFError("short TACACS+ read")
        chunks.append(data)
        remaining -= len(data)
    return b"".join(chunks)


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


def exchange(packet_type, body, timeout=4):
    session_id = random.getrandbits(32)
    if SEND_UNENCRYPTED:
        flags = UNENCRYPTED
        wire_body = body
    else:
        flags = 0
        wire_body = tacacs_crypt(body, 0xC0, 1, session_id)
    header = struct.pack("!BBBBII", 0xC0, packet_type, 1, flags, session_id, len(body))
    with socket.create_connection((TACACS_HOST, TACACS_PORT), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(header + wire_body)
        reply_header = recv_exact(sock, 12)
        version, reply_type, seq_no, flags, reply_session, length = struct.unpack("!BBBBII", reply_header)
        if version != 0xC0 or reply_type != packet_type or seq_no != 2 or reply_session != session_id:
            raise ValueError("invalid TACACS+ reply header")
        reply_body = recv_exact(sock, length)
        if flags & UNENCRYPTED:
            return reply_body
        return tacacs_crypt(reply_body, version, seq_no, reply_session)


def checked_len(value, label):
    if len(value) > 255:
        raise ValueError(f"{label} is too long for TACACS+ field")
    return len(value)


def authen_start(username, password, rhost):
    user = username.encode("utf-8")
    port = b"ssh"
    rem_addr = rhost.encode("utf-8")
    secret = password.encode("utf-8")
    body = bytes([
        AUTHEN_LOGIN,
        1,
        AUTHEN_TYPE_PAP,
        AUTHEN_SERVICE_LOGIN,
        checked_len(user, "username"),
        checked_len(port, "port"),
        checked_len(rem_addr, "remote host"),
        checked_len(secret, "password"),
    ]) + user + port + rem_addr + secret
    reply = exchange(AUTHEN, body)
    if len(reply) < 6:
        raise ValueError("short TACACS+ authentication reply")
    status, _flags, msg_len, data_len = struct.unpack("!BBHH", reply[:6])
    message = reply[6:6 + msg_len].decode("utf-8", "replace")
    return status == AUTHEN_STATUS_PASS, message or "no_message"


def author_request(username, resource, rhost):
    user = username.encode("utf-8")
    port = b"ssh"
    rem_addr = rhost.encode("utf-8")
    args = [
        b"service=ssh",
        f"resource={resource}".encode("utf-8"),
        f"host={socket.gethostname()}".encode("utf-8"),
    ]
    body = bytes([
        AUTHEN_METHOD_TACACSPLUS,
        1,
        AUTHEN_TYPE_PAP,
        AUTHEN_SERVICE_LOGIN,
        checked_len(user, "username"),
        checked_len(port, "port"),
        checked_len(rem_addr, "remote host"),
        checked_len(args, "argument count"),
    ]) + user + port + rem_addr + bytes(checked_len(arg, "argument") for arg in args) + b"".join(args)
    reply = exchange(AUTHOR, body)
    if len(reply) < 6:
        raise ValueError("short TACACS+ authorization reply")
    status, arg_cnt, msg_len, data_len = struct.unpack("!BBHH", reply[:6])
    offset = 6 + arg_cnt
    message = reply[offset:offset + msg_len].decode("utf-8", "replace")
    return status in (AUTHOR_STATUS_PASS_ADD, AUTHOR_STATUS_PASS_REPL), message or "no_message"


def main():
    username = os.environ.get("PAM_USER", "")
    rhost = os.environ.get("PAM_RHOST", "")
    password = sys.stdin.buffer.read().strip(b"\x00\r\n").decode("utf-8", "replace")
    resource = read_resource()

    try:
        auth_ok, auth_reason = authen_start(username, password, rhost)
        if auth_ok:
            author_ok, author_reason = author_request(username, resource, rhost)
        else:
            author_ok, author_reason = False, "authentication_failed"
    except Exception as exc:
        auth_ok, auth_reason = False, f"tacacs_unreachable:{exc}"
        author_ok, author_reason = False, "authorization_skipped"

    ok = auth_ok and author_ok
    log_event({
        "username": username,
        "resource": resource,
        "rhost": rhost,
        "ok": ok,
        "auth_ok": auth_ok,
        "auth_reason": auth_reason,
        "author_ok": author_ok,
        "author_reason": author_reason,
        "server": f"{TACACS_HOST}:{TACACS_PORT}",
    })
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
