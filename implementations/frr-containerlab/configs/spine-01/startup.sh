#!/bin/bash
set -e
for IFACE in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9 eth10; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

iptables -A INPUT -p tcp --dport 179 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -j DROP

for BFD_PORT in 3784 3785 4784; do
  iptables -A INPUT -p udp --dport "$BFD_PORT" -s 10.0.0.0/16 -j ACCEPT
  iptables -A INPUT -p udp --dport "$BFD_PORT" -j DROP
done

iptables -A INPUT -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP
