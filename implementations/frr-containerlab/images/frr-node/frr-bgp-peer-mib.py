#!/usr/bin/env python3
import json
import subprocess
import sys

BASE = (1, 3, 6, 1, 2, 1, 15, 3, 1)
STATE = {
    "Idle": 1,
    "Connect": 2,
    "Active": 3,
    "OpenSent": 4,
    "OpenConfirm": 5,
    "Established": 6,
}


def parse_oid(value):
    value = value.strip().lstrip(".")
    if not value:
        return ()
    return tuple(int(part) for part in value.split("."))


def fmt_oid(value):
    return "." + ".".join(str(part) for part in value)


def bgp_summary():
    result = subprocess.run(
        ["vtysh", "-c", "show bgp summary json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return {}
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    return data.get("ipv4Unicast", {}).get("peers", {})


def rows():
    entries = {}
    for peer, data in bgp_summary().items():
        try:
            suffix = tuple(int(part) for part in peer.split("."))
        except ValueError:
            continue

        state = STATE.get(str(data.get("state", "")), 1)
        version = int(data.get("version") or 4)
        remote_as = int(data.get("remoteAs") or 0)
        msg_rcvd = int(data.get("msgRcvd") or 0)
        msg_sent = int(data.get("msgSent") or 0)
        established = int(data.get("connectionsEstablished") or 0)
        uptime = int(int(data.get("peerUptimeMsec") or 0) / 1000)

        entries[BASE + (1,) + suffix] = ("ipaddress", peer)
        entries[BASE + (2,) + suffix] = ("integer", state)
        entries[BASE + (3,) + suffix] = ("integer", 2)
        entries[BASE + (4,) + suffix] = ("integer", version)
        entries[BASE + (7,) + suffix] = ("ipaddress", peer)
        entries[BASE + (9,) + suffix] = ("integer", remote_as)
        entries[BASE + (12,) + suffix] = ("counter", msg_rcvd)
        entries[BASE + (13,) + suffix] = ("counter", msg_sent)
        entries[BASE + (15,) + suffix] = ("counter", established)
        entries[BASE + (16,) + suffix] = ("gauge", uptime)
    return entries


def respond(oid, value):
    value_type, value_data = value
    print(fmt_oid(oid), flush=True)
    print(value_type, flush=True)
    print(value_data, flush=True)


def main():
    while True:
        command = sys.stdin.readline()
        if not command:
            break
        command = command.strip()

        if command == "PING":
            print("PONG", flush=True)
            continue

        oid = parse_oid(sys.stdin.readline())
        current = rows()

        if command == "get":
            value = current.get(oid)
            if value is None:
                print("NONE", flush=True)
            else:
                respond(oid, value)
        elif command == "getnext":
            next_oid = next((item for item in sorted(current) if item > oid), None)
            if next_oid is None:
                print("NONE", flush=True)
            else:
                respond(next_oid, current[next_oid])
        else:
            print("NONE", flush=True)


if __name__ == "__main__":
    main()
