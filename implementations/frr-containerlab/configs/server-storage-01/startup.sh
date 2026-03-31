#!/bin/sh
set -eu

ip addr add 192.168.80.10/24 dev eth1
ip route del default || true
ip route add default via 192.168.80.1 dev eth1
iptables -I INPUT -i eth0 -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 22 -j DROP
