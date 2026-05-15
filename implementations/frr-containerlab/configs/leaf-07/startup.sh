#!/bin/bash
set -e
VTEP_IP="10.1.0.17"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

modprobe br_netfilter 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=1
sysctl -w net.bridge.bridge-nf-call-ip6tables=1

iptables -t mangle -N ESI_QOS 2>/dev/null || true
iptables -t mangle -F ESI_QOS
iptables -t mangle -D PREROUTING -j ESI_QOS 2>/dev/null || true
iptables -t mangle -A PREROUTING -j ESI_QOS

for PORT in 873 21 2049 445; do
  iptables -t mangle -A ESI_QOS -p tcp -s 192.168.80.0/24 --dport "$PORT" -j DSCP --set-dscp-class CS1
  iptables -t mangle -A ESI_QOS -p tcp -d 192.168.80.0/24 --sport "$PORT" -j DSCP --set-dscp-class CS1
  iptables -t mangle -A ESI_QOS -p udp -s 192.168.80.0/24 --dport "$PORT" -j DSCP --set-dscp-class CS1
  iptables -t mangle -A ESI_QOS -p udp -d 192.168.80.0/24 --sport "$PORT" -j DSCP --set-dscp-class CS1
done

for SUBNET in 192.168.70.0/24 192.168.80.0/24; do
  iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -s "$SUBNET" -j DSCP --set-dscp-class AF31
  iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -d "$SUBNET" -j DSCP --set-dscp-class AF31
done

iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -s 192.168.90.0/24 -j DSCP --set-dscp-class AF41
iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -d 192.168.90.0/24 -j DSCP --set-dscp-class AF41

for SUBNET in 192.168.30.0/24 192.168.40.0/24 192.168.50.0/24 192.168.10.0/24; do
  iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -s "$SUBNET" -j DSCP --set-dscp-class AF21
  iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -d "$SUBNET" -j DSCP --set-dscp-class AF21
done

iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -s 192.168.20.0/24 -j DSCP --set-dscp-class AF11
iptables -t mangle -A ESI_QOS -m dscp --dscp 0x00 -d 192.168.20.0/24 -j DSCP --set-dscp-class AF11

iptables -t mangle -N ESI_QOS_OUT 2>/dev/null || true
iptables -t mangle -F ESI_QOS_OUT
iptables -t mangle -D OUTPUT -j ESI_QOS_OUT 2>/dev/null || true
iptables -t mangle -A OUTPUT -j ESI_QOS_OUT

iptables -t mangle -A ESI_QOS_OUT -p tcp --sport 179 -j DSCP --set-dscp-class CS6
iptables -t mangle -A ESI_QOS_OUT -p tcp --dport 179 -j DSCP --set-dscp-class CS6
for BFD_PORT in 3784 3785 4784; do
  iptables -t mangle -A ESI_QOS_OUT -p udp --sport "$BFD_PORT" -j DSCP --set-dscp-class CS6
  iptables -t mangle -A ESI_QOS_OUT -p udp --dport "$BFD_PORT" -j DSCP --set-dscp-class CS6
done

# RING 3: Allow BGP and BFD from known peer subnets, SSH from management subnet, and VTEP control traffic from all leafs. Drop all other attempts to connect to these services on the leaf itself.
iptables -A INPUT -p tcp --dport 179 -s 10.0.0.0/16 -j ACCEPT
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

ip link add VRF-STAFF type vrf table 20
ip link set VRF-STAFF up

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

if ip link show eth3 >/dev/null 2>&1; then ip link set eth3 master br0; bridge vlan add vid 80 dev eth3 pvid untagged; ip link set eth3 up; fi
if ip link show eth4 >/dev/null 2>&1; then ip link set eth4 master br0; bridge vlan add vid 80 dev eth4 pvid untagged; ip link set eth4 up; fi

ip link add vxlan10080 type vxlan id 10080 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan10080 mtu 9000
ip link set vxlan10080 master br0
ip link set vxlan10080 up
bridge vlan add vid 80 dev vxlan10080 pvid untagged
bridge vlan add vid 80 dev br0 self
bridge vlan add vid 4020 dev br0 self

ip link add vxlan50020 type vxlan id 50020 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50020 mtu 9000
ip link set vxlan50020 master br0
ip link set vxlan50020 up
bridge vlan add vid 4020 dev vxlan50020 pvid untagged

ip link add vlan80 link br0 type vlan id 80
ip link set vlan80 master VRF-STAFF
ip link set vlan80 address $ANYCAST_MAC || true
ip addr add 192.168.80.1/24 dev vlan80
ip link set vlan80 up

ip link add vlan4020 link br0 type vlan id 4020
ip link set vlan4020 master VRF-STAFF
ip link set vlan4020 up

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
      seed_l2vni_macs 10080 80 vxlan10080 vlan80
      seed_l3vni_rmacs 50020 4020 vxlan50020 vlan4020
      sleep 30
    done
  ) >/var/log/l3vni-rmac-seed.log 2>&1 &
  echo $! > "$pidfile"
}

start_l3vni_rmac_seed_loop

# === END PHASE 1 — Phase 2 appends below ===

# Ring 4: OOB management for bastion-only SSH
OOB_IF="eth10"
ip addr replace 172.16.0.27/24 dev "$OOB_IF"
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
server 192.168.50.20 iburst prefer minpoll 0 maxpoll 2
# Fallback: if NTP server unreachable, use local clock at high stratum
local stratum 10
# Accept clock step on first 3 syncs
makestep 1.0 3
# Accept the lab local source quickly; tests enforce resulting clock offset < 1s
maxdistance 16.0
logdir /var/log/chrony
log measurements statistics tracking
EOF

mkdir -p /var/log/chrony

# Start chronyd in background — use & and not exec so startup.sh continues
chronyd -f /etc/chrony.conf &

# === DHCP RELAY ===
nohup python3 /usr/local/bin/esi-dhcp-relay.py \
  --server 192.168.50.40 \
  --relay-ip "$VTEP_IP" \
  --interface vlan80=192.168.80.1 >/var/log/esi-dhcp-relay.log 2>&1 &


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
