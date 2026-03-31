#!/bin/bash
set -e
for IFACE in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9 eth10; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

# Ring 4: restrict OOB SSH access to bastion-01 only
iptables -I INPUT -i eth0 -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 22 -j DROP
