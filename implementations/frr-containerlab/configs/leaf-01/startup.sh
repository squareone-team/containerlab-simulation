#!/bin/bash
set -e
VTEP_IP="10.1.0.11"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1


# RING 3: Allow BGP and BFD from known peer subnets, SSH from management subnet, and VTEP control traffic from all leafs. Drop all other attempts to connect to these services on the leaf itself.
iptables -A INPUT -p tcp --dport 179 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -s 203.0.113.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -s 203.0.114.0/30 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -j DROP

for BFD_PORT in 3784 3785 4784; do
  iptables -A INPUT -p udp --dport "$BFD_PORT" -s 10.0.0.0/16 -j ACCEPT
  iptables -A INPUT -p udp --dport "$BFD_PORT" -j DROP
done

iptables -A INPUT -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP

for AUTH_VTEP in 10.1.0.1 10.1.0.2 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20; do
  iptables -A INPUT -p udp --dport 4789 -s "$AUTH_VTEP" -j ACCEPT
done
iptables -A INPUT -p udp --dport 4789 -j DROP

ip link add VRF-PEDAGOGY type vrf table 30
ip link set VRF-PEDAGOGY up
ip link add VRF-STAFF type vrf table 20
ip link set VRF-STAFF up
ip link add VRF-PUBLIC type vrf table 40
ip link set VRF-PUBLIC up
ip link add VRF-ORIENTATION type vrf table 50
ip link set VRF-ORIENTATION up
ip link add VRF-WIFI-CTRL type vrf table 60
ip link set VRF-WIFI-CTRL up
for IFACE in eth3 eth4 eth5 eth6 eth7 eth8 eth9; do
  ip link set dev $IFACE mtu 9000 || true
done

if ip link show eth3 >/dev/null 2>&1; then
  ip link set eth3 master VRF-PUBLIC
  ip addr add 203.0.113.1/30 dev eth3 2>/dev/null || true
  ip link set eth3 up
fi

ip link set eth8 master VRF-WIFI-CTRL
ip addr add 10.200.0.1/30 dev eth8
ip link set eth8 up

ip link add br-fw-ha type bridge vlan_filtering 1 vlan_default_pvid 1
ip link set br-fw-ha mtu 9000
ip link set br-fw-ha up
ip link set eth5 master br-fw-ha
ip link set eth9 master br-fw-ha
ip link set eth5 up
ip link set eth9 up
ip addr add 192.168.1.252/24 dev br-fw-ha

# Policy routing for packets returning from the firewall transit segment.
ip rule add iif br-fw-ha to 192.168.10.0/24 lookup 30 prio 10000 || true
ip rule add iif br-fw-ha to 192.168.20.0/24 lookup 30 prio 10001 || true
ip rule add iif br-fw-ha to 192.168.50.0/24 lookup 20 prio 10002 || true
ip rule add iif br-fw-ha to 192.168.60.0/24 lookup 20 prio 10003 || true
ip rule add iif br-fw-ha to 10.200.0.0/30 lookup 60 prio 10004 || true
ip rule add iif br-fw-ha to 192.168.110.0/24 lookup 60 prio 10005 || true
ip rule add iif br-fw-ha to 198.51.100.0/24 lookup 40 prio 10006 || true
ip rule add iif br-fw-ha from 192.168.50.0/24 lookup 30 prio 10010 || true
ip rule add iif br-fw-ha from 192.168.60.0/24 lookup 30 prio 10011 || true
ip rule add iif br-fw-ha from 192.168.10.0/24 lookup 20 prio 10012 || true
ip rule add iif br-fw-ha from 192.168.20.0/24 lookup 20 prio 10013 || true
ip rule add iif br-fw-ha from 192.168.70.0/24 lookup 20 prio 10014 || true
ip rule add iif br-fw-ha from 192.168.80.0/24 lookup 20 prio 10015 || true

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

for V in 10090 10100 10120; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 90 dev vxlan10090 pvid untagged
bridge vlan add vid 100 dev vxlan10100 pvid untagged
bridge vlan add vid 120 dev vxlan10120 pvid untagged
bridge vlan add vid 90 dev br0 self
bridge vlan add vid 100 dev br0 self
bridge vlan add vid 120 dev br0 self
bridge vlan add vid 4020 dev br0 self
bridge vlan add vid 4030 dev br0 self
bridge vlan add vid 4060 dev br0 self

ip link add vxlan50020 type vxlan id 50020 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50020 mtu 9000
ip link set vxlan50020 master br0
ip link set vxlan50020 up
bridge vlan add vid 4020 dev vxlan50020 pvid untagged

ip link add vxlan50030 type vxlan id 50030 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50030 mtu 9000
ip link set vxlan50030 master br0
ip link set vxlan50030 up
bridge vlan add vid 4030 dev vxlan50030 pvid untagged

ip link add vxlan50060 type vxlan id 50060 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50060 mtu 9000
ip link set vxlan50060 master br0
ip link set vxlan50060 up
bridge vlan add vid 4060 dev vxlan50060 pvid untagged

ip link add vlan4020 link br0 type vlan id 4020
ip link set vlan4020 master VRF-STAFF
ip link set vlan4020 up

ip link add vlan4030 link br0 type vlan id 4030
ip link set vlan4030 master VRF-PEDAGOGY
ip link set vlan4030 up

seed_l3vni_rmacs() {
  local rt="$1" vlan="$2" vxlan="$3" svi="$4"

  [ -e "/sys/class/net/$vxlan" ] && [ -e "/sys/class/net/$svi" ] || return 0

  vtysh -c "show bgp l2vpn evpn route type prefix" 2>/dev/null \
    | awk -v rt="RT:65000:${rt}" -v self="$VTEP_IP" '
        /^[[:space:]]*[*> ]*\[5\]/ { in_route=1; nh=""; next }
        in_route && $1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ { nh=$1; next }
        in_route && /Rmac:/ {
          rmac=""
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^Rmac:/) {
              rmac = substr($i, 6)
            }
          }
          if (index($0, rt) && nh != "" && nh != self && rmac != "") {
            print nh, rmac
          }
          in_route=0
        }
      ' \
    | while read -r nh rmac; do
        bridge fdb replace "$rmac" dev "$vxlan" dst "$nh" self 2>/dev/null || true
        bridge fdb replace "$rmac" dev "$vxlan" vlan "$vlan" master 2>/dev/null || true
        ip neigh replace "$nh" lladdr "$rmac" dev "$svi" nud permanent 2>/dev/null || true
      done
}

seed_l2vni_macs() {
  local vni="$1" vlan="$2" vxlan="$3" svi="$4"

  [ -e "/sys/class/net/$vxlan" ] || return 0

  bridge fdb del "$ANYCAST_MAC" dev "$vxlan" vlan "$vlan" master 2>/dev/null || true
  bridge fdb del "$ANYCAST_MAC" dev "$vxlan" self 2>/dev/null || true

  vtysh -c "show bgp l2vpn evpn route type multicast" 2>/dev/null \
    | awk -v vni="$vni" -v self="$VTEP_IP" '
        BEGIN {
          ipv4 = "^([0-9]{1,3}\.){3}[0-9]{1,3}$"
          rt_re = "RT:[0-9]+:" vni "([^0-9]|$)"
        }
        function reset_route() {
          in_route = 0
          nh = ""
        }
        /\[3\]:/ {
          in_route = 1
          nh = ""
          next
        }
        in_route && $1 ~ ipv4 { nh = $1; next }
        in_route && /RT:/ {
          if ($0 ~ rt_re && nh != "" && nh != self) {
            print nh
          }
          reset_route()
          next
        }
      ' \
    | while read -r nh; do
        bridge fdb del 00:00:00:00:00:00 dev "$vxlan" dst "$nh" self 2>/dev/null || true
        bridge fdb append 00:00:00:00:00:00 dev "$vxlan" dst "$nh" self 2>/dev/null || true
      done
}

start_l3vni_rmac_seed_loop() {
  local pidfile="/run/l3vni-rmac-seed.pid"

  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi

  (
    sleep 8
    while true; do
      seed_l2vni_macs 10090 90 vxlan10090 vlan90
      seed_l2vni_macs 10100 100 vxlan10100 vlan100
      seed_l2vni_macs 10120 120 vxlan10120 vlan120
      seed_l3vni_rmacs 50020 4020 vxlan50020 vlan4020
      seed_l3vni_rmacs 50030 4030 vxlan50030 vlan4030
      seed_l3vni_rmacs 50060 4060 vxlan50060 vlan4060
      sleep 30
    done
  ) >/var/log/l3vni-rmac-seed.log 2>&1 &
  echo $! > "$pidfile"
}

start_l3vni_rmac_seed_loop

ip link add vlan120 link br0 type vlan id 120
ip link set vlan120 master VRF-WIFI-CTRL
ip link set vlan120 address $ANYCAST_MAC || true
ip addr add 192.168.10.1/24 dev vlan120
ip link set vlan120 up
ip route replace 192.168.10.100/32 dev vlan120 vrf VRF-WIFI-CTRL
ip route replace 192.168.110.0/24 via 10.200.0.2 dev eth8 vrf VRF-WIFI-CTRL

if ip link show eth14 >/dev/null 2>&1; then
  ip link set eth14 master br0
  bridge vlan add vid 120 dev eth14 pvid untagged
fi

if ip link show eth7 >/dev/null 2>&1; then
  ip link set eth7 master br0
  bridge vlan add vid 100 dev eth7 pvid untagged
fi

ip link add vlan100 link br0 type vlan id 100
ip link set vlan100 master VRF-PUBLIC
ip link set vlan100 address $ANYCAST_MAC || true
ip addr add 198.51.100.1/24 dev vlan100
ip link set vlan100 up

# Keep public VRF clean: steer only DMZ-originated internal traffic into Ring 1
# via a dedicated policy-routing table instead of importing internal routes into
# VRF-PUBLIC itself.
FW_DMZ_TABLE=140
FW_INTERNAL_SUBNETS="
192.168.10.0/24
192.168.20.0/24
192.168.30.0/24
192.168.40.0/24
192.168.50.0/24
192.168.60.0/24
192.168.70.0/24
192.168.80.0/24
10.200.0.0/30
192.168.110.0/24
"

for SUBNET in $FW_INTERNAL_SUBNETS; do
  ip route replace table "$FW_DMZ_TABLE" "$SUBNET" via 192.168.1.254 dev br-fw-ha
done

PREF=70
for SUBNET in $FW_INTERNAL_SUBNETS; do
  ip rule add pref "$PREF" iif VRF-PUBLIC to "$SUBNET" lookup "$FW_DMZ_TABLE" 2>/dev/null || true
  PREF=$((PREF + 1))
done

PREF=91
for SUBNET in $FW_INTERNAL_SUBNETS; do
    ip rule add pref "$PREF" iif vlan100 to "$SUBNET" lookup "$FW_DMZ_TABLE" 2>/dev/null || true
  PREF=$((PREF + 1))
done

# Campus traffic keeps its dedicated micro-VRF uplink, but only the shared
# service IPs and the explicit DMZ test subnet are steered through Ring 1.
# No broader internal prefixes leak.
FW_CAMPUS_TABLE=160
FW_CAMPUS_SERVICE_IPS="
192.168.50.20/32
192.168.50.30/32
192.168.50.40/32
192.168.50.70/32
198.51.100.0/24
"

for SUBNET in $FW_CAMPUS_SERVICE_IPS; do
  ip route replace table "$FW_CAMPUS_TABLE" "$SUBNET" via 192.168.1.254 dev br-fw-ha
done

PREF=80
for SUBNET in $FW_CAMPUS_SERVICE_IPS; do
  ip rule add pref "$PREF" iif VRF-WIFI-CTRL to "$SUBNET" lookup "$FW_CAMPUS_TABLE" 2>/dev/null || true
  PREF=$((PREF + 1))
done

PREF=86
for SUBNET in $FW_CAMPUS_SERVICE_IPS; do
  ip rule add pref "$PREF" iif eth8 to "$SUBNET" lookup "$FW_CAMPUS_TABLE" 2>/dev/null || true
  PREF=$((PREF + 1))
done

ip link add vlan4060 link br0 type vlan id 4060
ip link set vlan4060 master VRF-WIFI-CTRL
ip link set vlan4060 up

# Inbound internet traffic to DMZ must use VRF-PUBLIC table.
ip rule add pref 90 iif eth3 to 198.51.100.0/24 lookup 40 2>/dev/null || true

# Inbound internet return traffic to student subnets must use VRF-PEDAGOGY.
ip rule add pref 100 iif eth3 to 192.168.10.0/24 lookup 30 2>/dev/null || true
ip rule add pref 101 iif eth3 to 192.168.20.0/24 lookup 30 2>/dev/null || true

# === END PHASE 1 — Phase 2 appends below ===

# =====================================================
# THEME T1 — BORDER ROUTING — Youcef
# Stateful guard: allow return traffic, block unsolicited internet->student.
# =====================================================
iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C FORWARD -i eth3 -d 192.168.10.0/24 -m conntrack --ctstate NEW -j DROP 2>/dev/null \
  || iptables -I FORWARD 2 -i eth3 -d 192.168.10.0/24 -m conntrack --ctstate NEW -j DROP
iptables -C FORWARD -i eth3 -d 192.168.20.0/24 -m conntrack --ctstate NEW -j DROP 2>/dev/null \
  || iptables -I FORWARD 3 -i eth3 -d 192.168.20.0/24 -m conntrack --ctstate NEW -j DROP
# Ring 4: OOB management for bastion-only SSH
OOB_IF="eth10"
ip addr replace 172.16.0.21/24 dev "$OOB_IF"
ip link set "$OOB_IF" up

# Ring 4: enable SSH daemon for bastion management
if ! command -v sshd >/dev/null 2>&1; then
  echo "Failed to install OpenSSH server on $(hostname)" >&2
  exit 1
fi

mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh
ssh-keygen -A

if grep -q '^PasswordAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
  echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
fi
if grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
else
  echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
fi
if grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
fi

/usr/sbin/sshd

iptables -C INPUT -i "$OOB_IF" -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$OOB_IF" -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -C INPUT -i "$OOB_IF" -p tcp --dport 22 -j DROP 2>/dev/null || iptables -A INPUT -i "$OOB_IF" -p tcp --dport 22 -j DROP

cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG

/usr/sbin/rsyslogd

# === NTP CLIENT ===
# Chrony is preinstalled in the lab image

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


# SNMP 
# ── rp_filter: loose mode (not disabled) ────────────────────────────────────
sysctl -w net.ipv4.conf.all.rp_filter=2      2>/dev/null || true
sysctl -w net.ipv4.conf.eth1.rp_filter=2     2>/dev/null || true
sysctl -w net.ipv4.conf.eth2.rp_filter=2     2>/dev/null || true
# Do NOT set accept_local=1 — that was papering over the wrong binding

# ── Wait for FRR to assign the loopback IP (health check only) ───────────────
echo "[snmp] waiting for FRR loopback IP..."
RETRIES=30
MY_IP=""
while [ $RETRIES -gt 0 ]; do
    MY_IP=$(ip addr show lo 2>/dev/null \
        | grep 'inet ' \
        | awk '{print $2}' \
        | cut -d/ -f1 \
    | grep -v '^127\.' || true)
    [ -n "$MY_IP" ] && break
    sleep 2
    RETRIES=$((RETRIES - 1))
done

if [ -z "$MY_IP" ]; then
    echo "[snmp] WARNING: FRR loopback IP never appeared on lo — FRR may have failed"
    MY_IP="<unknown>"
fi
echo "[snmp] FRR loopback IP: $MY_IP"

mkdir -p /etc/snmp /var/run/net-snmp /var/agentx
chmod 770 /var/agentx           # NOT 777 — agentx refuses world-writable sockets

# ── snmpd.conf ───────────────────────────────────────────────────────────────
# agentAddress udp:161  — listen on ALL interfaces (0.0.0.0:161)
# This is the critical fix. The SNMP request arrives on eth1/eth2 from
# zabbix-server. snmpd must be listening on those interfaces, not just lo.
# The rocommunity ACL still restricts who can actually poll.
cat > /etc/snmp/snmpd.conf << 'EOF'
# Listen on all interfaces — packets arrive on eth1/eth2, not on lo
agentAddress udp:161
 
# Community — restrict by source subnet
rocommunity esi-read 10.0.0.0/8
rocommunity esi-read 192.168.0.0/16
rocommunity esi-read 172.16.0.0/12
 
# System info
sysLocation ESI-Datacenter-Lab
sysContact  noc@esi.internal
sysServices 72
 
# AgentX — FRR subagent connects here to expose BGP/routing MIBs
master agentx
agentXSocket /var/agentx/master
pass_persist .1.3.6.1.2.1.15.3 /usr/local/bin/frr-bgp-peer-mib.py
 
# MIB views — expose standard MIBs that Zabbix polls
view systemview included .1.3.6.1.2.1.1
view systemview included .1.3.6.1.2.1.2
view systemview included .1.3.6.1.2.1.4
view systemview included .1.3.6.1.4.1.2021
EOF

# ── Start snmpd ──────────────────────────────────────────────────────────────
snmpd -C -c /etc/snmp/snmpd.conf -Lf /var/log/snmpd.log &
sleep 2

if pgrep snmpd > /dev/null; then
    echo "[snmp] snmpd started — listening on 0.0.0.0:161"
else
    echo "[snmp] ERROR: snmpd failed to start — check /var/log/snmpd.log"
    cat /var/log/snmpd.log 2>/dev/null || true
fi
