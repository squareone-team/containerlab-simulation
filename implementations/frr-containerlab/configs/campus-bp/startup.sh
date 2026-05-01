#!/bin/sh
set -eu

wait_for_iface() {
    iface="$1"
    retries="${2:-20}"
    while [ "$retries" -gt 0 ]; do
        if ip link show "$iface" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    return 1
}

hostname campus-bp

ip link add br-student type bridge 2>/dev/null || true
ip link set br-student up
ip addr replace 192.168.110.1/24 dev br-student

wait_for_iface eth1
ip link set eth1 up
ip addr replace 100.10.0.2/30 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 100.10.0.1 dev eth1

wait_for_iface eth3
ip link set eth3 up
ip addr replace 10.200.0.2/30 dev eth3
ip route replace 192.168.10.100/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.20/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.30/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.40/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.70/32 via 10.200.0.1 dev eth3

wait_for_iface eth4
ip link set eth4 up
ip link set eth4 master br-student

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

iptables -t nat -C POSTROUTING -s 192.168.110.0/24 -o eth1 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 192.168.110.0/24 -o eth1 -j MASQUERADE
