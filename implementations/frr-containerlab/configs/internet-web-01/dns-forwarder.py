#!/usr/bin/env python3
import socket
import struct
from socketserver import BaseRequestHandler, ThreadingUDPServer


LISTEN = ("0.0.0.0", 53)
GOOGLE_NAME = b"\x03www\x06google\x03com\x00"
GOOGLE_IP = "198.18.3.10"


def parse_question(packet):
    offset = 12
    labels = []
    while offset < len(packet):
        length = packet[offset]
        offset += 1
        if length == 0:
            break
        if offset + length > len(packet):
            return "", b"", 0
        labels.append(packet[offset:offset + length].decode("ascii", "ignore").lower())
        offset += length
    if offset + 4 > len(packet):
        return "", b"", 0
    qtype, qclass = struct.unpack("!HH", packet[offset:offset + 4])
    return ".".join(labels), packet[12:offset + 4], qtype, qclass


def response_for(packet):
    if len(packet) < 12:
        return b""

    txid = packet[:2]
    flags = 0x8180
    question_count = 1
    answer_count = 0
    name, question, qtype, qclass = parse_question(packet)
    answers = b""

    if name == "www.google.com" and qclass == 1 and qtype == 1:
        answer_count = 1
        answers = (
            b"\xc0\x0c"
            + struct.pack("!HHIH", 1, 1, 60, 4)
            + socket.inet_aton(GOOGLE_IP)
        )
    elif name == "www.google.com":
        # Known name but unsupported type: return NOERROR/NODATA so clients that
        # ask for AAAA after A do not report a mixed success/NXDOMAIN result.
        answer_count = 0
    else:
        flags = 0x8183

    header = txid + struct.pack("!HHHHH", flags, question_count, answer_count, 0, 0)
    return header + question + answers


class Handler(BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        payload = response_for(data)
        if payload:
            sock.sendto(payload, self.client_address)


class ReuseUDPServer(ThreadingUDPServer):
    allow_reuse_address = True


def main():
    server = ReuseUDPServer(LISTEN, Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
