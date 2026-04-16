#!/bin/sh
set -eu

ip addr add 192.168.20.10/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 192.168.20.1 dev eth1

for i in 1 2 3 4 5; do
  if apk update >/dev/null 2>&1 && apk add --no-cache nftables >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

cat > /etc/nftables.conf << 'NFT'
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;
    iif "lo" accept
    ct state established,related accept
    ip saddr 172.16.0.50 tcp dport 22 accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
NFT

nft -f /etc/nftables.conf

tail -f /dev/null
