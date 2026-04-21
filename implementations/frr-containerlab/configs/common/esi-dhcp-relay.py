#!/usr/bin/env python3
import argparse
import select
import socket
import sys
import time

COOKIE = b"\x63\x82\x53\x63"
SERVER_PORT = 67
CLIENT_PORT = 68
BINDTODEVICE = getattr(socket, "SO_BINDTODEVICE", 25)


def parse_interface(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected IFACE=LINK_IP")
    iface, link_ip = value.split("=", 1)
    iface = iface.strip()
    link_ip = link_ip.strip()
    if not iface:
        raise argparse.ArgumentTypeError("missing interface name")
    try:
        socket.inet_aton(link_ip)
    except OSError as exc:
        raise argparse.ArgumentTypeError(f"invalid IPv4 address: {link_ip}") from exc
    return iface, link_ip


def wait_for_relay_ip(relay_ip: str, timeout: int = 60) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.bind((relay_ip, 0))
            return
        except OSError:
            time.sleep(1)
        finally:
            probe.close()
    raise SystemExit(f"relay IP {relay_ip} did not become available within {timeout}s")


def packet_key(packet: bytes) -> bytes:
    hlen = min(packet[2], 16) if len(packet) > 2 else 16
    return packet[4:8] + packet[28 : 28 + hlen]


def strip_option_82(options: bytes) -> bytes:
    out = bytearray()
    idx = 0
    while idx < len(options):
        code = options[idx]
        if code == 0:
            out.append(0)
            idx += 1
            continue
        if code == 255:
            out.append(255)
            break
        if idx + 1 >= len(options):
            break
        length = options[idx + 1]
        chunk = options[idx : idx + 2 + length]
        if code != 82:
            out.extend(chunk)
        idx += 2 + length
    if not out or out[-1] != 255:
        out.append(255)
    return bytes(out)


def add_link_selection(packet: bytes, relay_ip: str, link_ip: str) -> bytes | None:
    if len(packet) < 240 or packet[236:240] != COOKIE:
        return None

    header = bytearray(packet[:236])
    if header[0] != 1:
        return None
    if any(header[24:28]):
        return None

    header[3] = min(header[3] + 1, 255)
    header[24:28] = socket.inet_aton(relay_ip)

    options = strip_option_82(packet[240:])
    if options and options[-1] == 255:
        options = options[:-1]

    payload = bytes([5, 4]) + socket.inet_aton(link_ip)
    return bytes(header) + COOKIE + options + bytes([82, len(payload)]) + payload + b"\xff"


def clear_relay_state(packet: bytes) -> bytes:
    if len(packet) < 240 or packet[236:240] != COOKIE:
        return packet
    header = bytearray(packet[:236])
    header[24:28] = b"\x00\x00\x00\x00"
    options = strip_option_82(packet[240:])
    return bytes(header) + COOKIE + options


def make_socket(bind_addr: tuple[str, int] | None = None, iface: str | None = None, broadcast: bool = False) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    if broadcast:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    if iface:
        sock.setsockopt(socket.SOL_SOCKET, BINDTODEVICE, iface.encode() + b"\0")
    if bind_addr:
        sock.bind(bind_addr)
    return sock


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal DHCP relay for multihomed lab leaves")
    parser.add_argument("--server", required=True, help="DHCP server IPv4 address")
    parser.add_argument("--relay-ip", required=True, help="Unique IPv4 address used as giaddr")
    parser.add_argument(
        "--interface",
        dest="interfaces",
        action="append",
        type=parse_interface,
        required=True,
        metavar="IFACE=LINK_IP",
        help="Downstream interface and anycast gateway IP for that client VLAN",
    )
    args = parser.parse_args()

    wait_for_relay_ip(args.relay_ip)

    upstream = make_socket((args.relay_ip, SERVER_PORT))
    downstream_by_socket: dict[socket.socket, tuple[str, str]] = {}
    for iface, link_ip in args.interfaces:
        downstream_by_socket[make_socket(("0.0.0.0", SERVER_PORT), iface=iface, broadcast=True)] = (iface, link_ip)

    print(
        f"[relay] server={args.server} relay_ip={args.relay_ip} interfaces="
        + ",".join(f"{iface}:{link_ip}" for iface, link_ip in args.interfaces),
        flush=True,
    )

    inflight: dict[bytes, tuple[socket.socket, str, float]] = {}
    monitored = [upstream, *downstream_by_socket.keys()]

    while True:
        readable, _, _ = select.select(monitored, [], [], 5)
        now = time.time()
        inflight = {key: value for key, value in inflight.items() if now - value[2] < 60}

        for sock in readable:
            packet, addr = sock.recvfrom(4096)
            if len(packet) < 240:
                continue

            key = packet_key(packet)
            if sock is upstream:
                downstream = inflight.get(key)
                if not downstream:
                    print(f"[relay] dropping reply from {addr[0]}:{addr[1]} with unknown xid", flush=True)
                    continue
                client_socket, iface, _ = downstream
                reply = clear_relay_state(packet)
                client_socket.sendto(reply, ("255.255.255.255", CLIENT_PORT))
                print(f"[relay] reply via {iface} xid={packet[4:8].hex()}", flush=True)
                continue

            iface, link_ip = downstream_by_socket[sock]
            forwarded = add_link_selection(packet, args.relay_ip, link_ip)
            if forwarded is None:
                continue
            inflight[key] = (sock, iface, now)
            upstream.sendto(forwarded, (args.server, SERVER_PORT))
            print(f"[relay] request on {iface} xid={packet[4:8].hex()}", flush=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        sys.exit(0)
