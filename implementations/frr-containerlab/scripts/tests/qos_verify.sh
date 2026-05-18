#!/bin/bash
set -e

C="docker exec clab-esi-datacenter"
PASS=0
FAIL=0

ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $1"; }

check_cmd() {
  local desc=$1
  local cmd=$2
  if eval "$cmd" >/dev/null 2>&1; then
    ok "$desc"
  else
    fail "$desc"
  fi
}

echo "=== QoS Verification ==="

# Leaf marking rules
for NODE in leaf-01 leaf-02 leaf-03 leaf-05 leaf-07 leaf-09 leaf-10; do
  check_cmd "$NODE: ESI_QOS chain exists" "$C-$NODE iptables -t mangle -S ESI_QOS | grep -q ESI_QOS"
  check_cmd "$NODE: control-plane CS6 rules" "$C-$NODE iptables -t mangle -S ESI_QOS_OUT | grep -q -- '--dport 179'"
  check_cmd "$NODE: storage AF31 rule" "$C-$NODE iptables -t mangle -S ESI_QOS | grep -q '192.168.80.0/24.*set-dscp 0x1a'"
  check_cmd "$NODE: bulk CS1 rule" "$C-$NODE iptables -t mangle -S ESI_QOS | grep -q '192.168.80.0/24.*set-dscp 0x08'"
  check_cmd "$NODE: BAC AF41 rule" "$C-$NODE iptables -t mangle -S ESI_QOS | grep -q '192.168.90.0/24.*set-dscp 0x22'"
  check_cmd "$NODE: student AF11 rule" "$C-$NODE iptables -t mangle -S ESI_QOS | grep -q '192.168.20.0/24.*set-dscp 0x0a'"
  check_cmd "$NODE: interactive AF21 rule" "$C-$NODE iptables -t mangle -S ESI_QOS | grep -q '192.168.30.0/24.*set-dscp 0x12'"
  echo ""
done

# Edge shaping/policing now lives on the routed border/firewall path.
check_cmd "border-router-01: ISP-facing link shaping" "$C-border-router-01 tc qdisc show dev eth1 | grep -q 'tbf'"
check_cmd "border-router-01: ISP-facing ingress qdisc" "$C-border-router-01 tc qdisc show dev eth1 | grep -q 'ingress'"
check_cmd "firewall-01: outside IPS ingress policing" "$C-firewall-01 tc filter show dev eth4 ingress | grep -Eq 'dst_ip 198\\.51\\.100\\.10|police'"
check_cmd "firewall-02: outside IPS ingress policing" "$C-firewall-02 tc filter show dev eth4 ingress | grep -Eq 'dst_ip 198\\.51\\.100\\.10|police'"

# Spine scheduling
check_cmd "spine-01: HTB root" "$C-spine-01 tc qdisc show dev eth1 | grep -q 'htb'"
check_cmd "spine-01: DSCP filters" "$C-spine-01 tc filter show dev eth1 parent 1: | grep -q 'match 00c0'"
check_cmd "spine-02: HTB root" "$C-spine-02 tc qdisc show dev eth1 | grep -q 'htb'"

# VXLAN DSCP preservation
check_cmd "leaf-09: vxlan tos inherit" "$C-leaf-09 ip -d link show vxlan10010 | grep -q 'tos inherit'"

# ECN on HPC leafs
check_cmd "leaf-05: ECN sysctl" "$C-leaf-05 sysctl net.ipv4.tcp_ecn | grep -q '= 2'"
check_cmd "leaf-05: ECN qdisc" "$C-leaf-05 tc qdisc show dev eth1 | grep -q 'fq_codel.*ecn'"
check_cmd "leaf-06: ECN sysctl" "$C-leaf-06 sysctl net.ipv4.tcp_ecn | grep -q '= 2'"
check_cmd "leaf-06: ECN qdisc" "$C-leaf-06 tc qdisc show dev eth1 | grep -q 'fq_codel.*ecn'"

# Optional congestion test if iperf3 exists
if $C-server-hpc-01 command -v apk >/dev/null 2>&1; then
  if ! $C-server-hpc-01 command -v iperf3 >/dev/null 2>&1; then
    $C-server-hpc-01 apk add --no-cache iperf3 >/dev/null 2>&1 || true
  fi
  if ! $C-server-hpc-02 command -v iperf3 >/dev/null 2>&1; then
    $C-server-hpc-02 apk add --no-cache iperf3 >/dev/null 2>&1 || true
  fi
fi

if $C-server-hpc-01 command -v iperf3 >/dev/null 2>&1 && $C-server-hpc-02 command -v iperf3 >/dev/null 2>&1; then
  info "Running AF31 (HPC) iperf3 load to populate class counters."
  $C-server-hpc-01 pkill iperf3 >/dev/null 2>&1 || true
  $C-server-hpc-01 iperf3 -s -D >/dev/null 2>&1
  BEFORE=$($C-spine-01 tc -s class show dev eth1 | awk '/class htb 1:40/{getline; print $2}' | tr -d 'bytes')
  $C-server-hpc-02 iperf3 -c 192.168.70.1 -P 4 -t 8 >/dev/null 2>&1 || true
  AFTER=$($C-spine-01 tc -s class show dev eth1 | awk '/class htb 1:40/{getline; print $2}' | tr -d 'bytes')
  if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$AFTER" -gt "$BEFORE" ] 2>/dev/null; then
    ok "AF31 class counters increased under load"
  else
    fail "AF31 class counters did not increase"
  fi
else
  info "iperf3 not available on HPC servers; skipping congestion test."
fi

info "AF41 (BAC) load test requires a BAC host in 192.168.90.0/24."

echo ""
echo "QoS Test Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "QoS checks PASSED" || echo "QoS checks FAILED"
