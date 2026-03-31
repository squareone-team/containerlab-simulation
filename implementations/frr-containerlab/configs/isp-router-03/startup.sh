#!/bin/sh
set -eu

iptables -I INPUT -i eth0 -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 22 -j DROP
