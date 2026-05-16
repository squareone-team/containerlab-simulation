#!/bin/sh
set -eu

hostname ids-01

wait_for_iface() {
  iface="$1"
  retries="${2:-30}"
  while [ "$retries" -gt 0 ]; do
    if ip link show "$iface" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    retries=$((retries - 1))
  done
  echo "ERROR: interface $iface did not appear" >&2
  return 1
}

wait_for_iface eth1
wait_for_iface eth2

ip link add br-ips type bridge 2>/dev/null || true
ip link set br-ips type bridge stp_state 0 2>/dev/null || true
ip link set br-ips mtu 9000 2>/dev/null || true
ip link set br-ips up

for iface in eth1 eth2; do
  ip link set "$iface" mtu 9000 2>/dev/null || true
  ip link set "$iface" up
  ip link set "$iface" master br-ips
done

# OOB address uses containerlab management eth0 so the transparent data path
# stays the only rendered topology edge for the IDS node.
ip addr replace 172.16.0.51/24 dev eth0

# This host kernel does not expose nftables bridge-family support, so the v1
# prevention wall uses tc ingress policing on the outside-facing bridge port.
# Only excessive TCP SYNs to the DMZ HTTP service are policed; ARP, BGP, ICMP,
# and established HTTP payloads stay transparent through the bridge.
tc qdisc del dev eth2 clsact 2>/dev/null || true
tc qdisc add dev eth2 clsact
tc filter add dev eth2 ingress protocol ip pref 10 flower \
  ip_proto tcp dst_ip 198.51.100.10 dst_port 80 tcp_flags 0x02/0x02 \
  action police rate 4kbit burst 1k conform-exceed drop

cat > /usr/local/bin/ids-ips-summary << 'SUMMARY'
#!/bin/sh
set -eu

echo "=== ids-01 inline IPS summary ==="
for iface in br-ips eth1 eth2; do
  ip -br link show "$iface" 2>/dev/null || true
done
echo
tc -s filter show dev eth2 ingress
SUMMARY
chmod +x /usr/local/bin/ids-ips-summary

{
  echo "ids-01 inline IPS started"
  echo "bridge: eth1 <-> eth2"
  echo "oob: 172.16.0.51/24 on eth0"
  echo "ddos rule: police excess TCP SYN to 198.51.100.10:80 on eth2 ingress"
} >/var/log/ids-ips.log

ids-ips-summary
