#!/bin/bash
set -e
VTEP_IP="10.1.0.14"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

ip link add VRF-STAFF type vrf table 20
ip link set VRF-STAFF up

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

if ip link show eth3 >/dev/null 2>&1; then ip link set eth3 master br0; bridge vlan add vid 50 dev eth3 pvid untagged; fi
if ip link show eth4 >/dev/null 2>&1; then ip link set eth4 master br0; bridge vlan add vid 40 dev eth4 pvid untagged; fi

for V in 10030 10040 10050; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 30 dev vxlan10030 pvid untagged
bridge vlan add vid 40 dev vxlan10040 pvid untagged
bridge vlan add vid 50 dev vxlan10050 pvid untagged
bridge vlan add vid 30 dev br0 self
bridge vlan add vid 40 dev br0 self
bridge vlan add vid 50 dev br0 self
bridge vlan add vid 4020 dev br0 self

ip link add vxlan50020 type vxlan id 50020 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50020 mtu 9000
ip link set vxlan50020 master br0
ip link set vxlan50020 up
bridge vlan add vid 4020 dev vxlan50020 pvid untagged

ip link add vlan30 link br0 type vlan id 30
ip link set vlan30 master VRF-STAFF
ip link set vlan30 address $ANYCAST_MAC || true
ip addr add 192.168.30.1/24 dev vlan30
ip link set vlan30 up

ip link add vlan40 link br0 type vlan id 40
ip link set vlan40 master VRF-STAFF
ip link set vlan40 address $ANYCAST_MAC || true
ip addr add 192.168.40.1/24 dev vlan40
ip link set vlan40 up

ip link add vlan50 link br0 type vlan id 50
ip link set vlan50 master VRF-STAFF
ip link set vlan50 address $ANYCAST_MAC || true
ip addr add 192.168.50.1/24 dev vlan50
ip link set vlan50 up

ip link add vlan4020 link br0 type vlan id 4020
ip link set vlan4020 master VRF-STAFF
ip link set vlan4020 up

# === END PHASE 1 — Phase 2 appends below ===

# === NTP CLIENT ===
# Install chrony
apk add --no-cache chrony

# Write client config
cat > /etc/chrony.conf << 'EOF'
# Sync from lab NTP server (stratum 2)
server 192.168.50.20 iburst prefer


# Fallback: if NTP server unreachable, use local clock at high stratum
local stratum 10

# Accept clock step on first 3 syncs
makestep 1.0 3

# Maximum skew allowed before chrony refuses to sync (forensic requirement: < 1s)
maxdistance 1.0

logdir /var/log/chrony
log measurements statistics tracking
EOF

mkdir -p /var/log/chrony

# Start chronyd in background — use & and not exec so startup.sh continues
chronyd -f /etc/chrony.conf &

# CORE-INFRA route leak to global routing table 
# Needed so FRR nodes (spines/leaves) can reach NTP/DNS in VRF-STAFF via underlay
# ip rule: for packets destined to 192.168.50.0/24, consult VRF-STAFF table (20)
ip rule add to 192.168.50.0/24 lookup 20 prio 100 2>/dev/null || true

# Add a static route in the main table so FRR BGP can advertise the prefix to spines
# Actual forwarding is handled by the ip rule above
ip route add 192.168.50.0/24 nhid 0 2>/dev/null || \
ip route add 192.168.50.0/24 dev vlan50 2>/dev/null || true

# === DHCP RELAY ===
apk add --no-cache dhcrelay
dhcrelay -4 \
  -id vlan30 \
  -id vlan40 \
  -id vlan50 \
  -id vlan60 \
  -iu vlan50 \
  192.168.50.40 &