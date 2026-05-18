#!/bin/sh
set -eu

hostname border-router-01

for iface in eth1 eth2 eth3; do
  if ip link show "$iface" >/dev/null 2>&1; then
    ip link set dev "$iface" mtu 9000 2>/dev/null || true
    ip link set dev "$iface" up
  fi
done

ip link add br-fw-out type bridge 2>/dev/null || true
ip link set br-fw-out mtu 9000 2>/dev/null || true
ip link set br-fw-out up

for iface in eth2 eth3; do
  if ip link show "$iface" >/dev/null 2>&1; then
    ip link set "$iface" master br-fw-out
  fi
done

ip addr replace 203.0.113.9/29 dev br-fw-out
ip route replace 198.51.100.0/24 via 203.0.113.14 dev br-fw-out

cat > /usr/local/bin/install_border_routes.sh <<'EOF'
#!/bin/sh
set -e

# Keep lab Internet return traffic on the ISP-facing data plane. The container
# management default route is intentionally left intact for OOB access.
ip route replace 198.18.0.0/15 via 203.0.113.2 dev eth1
ip route replace 198.51.100.0/24 via 203.0.113.14 dev br-fw-out
EOF
chmod +x /usr/local/bin/install_border_routes.sh
/usr/local/bin/install_border_routes.sh

cat > /usr/local/bin/start_border_route_sync.sh <<'EOF'
#!/bin/sh
pidfile="/run/border-route-sync.pid"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
(
  while true; do
    /usr/local/bin/install_border_routes.sh >/dev/null 2>&1 || true
    sleep 2
  done
) &
echo $! > "$pidfile"
EOF
chmod +x /usr/local/bin/start_border_route_sync.sh
/usr/local/bin/start_border_route_sync.sh

tc qdisc del dev eth1 root 2>/dev/null || true
tc qdisc del dev eth1 ingress 2>/dev/null || true
tc qdisc add dev eth1 root handle 1: tbf rate 950mbit burst 64kbit latency 50ms 2>/dev/null || true
tc qdisc add dev eth1 ingress 2>/dev/null || true

iptables -I INPUT -i eth0 -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 22 -j DROP
