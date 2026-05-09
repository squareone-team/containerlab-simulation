#!/bin/sh
set -eu

hostname vpn-client-01

ip link set eth1 up
ip addr replace 198.18.4.20/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 198.18.4.1 dev eth1
