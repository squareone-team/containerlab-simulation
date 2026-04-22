#!/usr/bin/env bash
set -euo pipefail

CLAB_PREFIX="clab-esi-datacenter"

pass=0
fail=0

ok() { echo "[PASS] $1"; pass=$((pass + 1)); }
ko() { echo "[FAIL] $1"; fail=$((fail + 1)); }

run_node() {
  local node="$1"
  shift
  docker exec "${CLAB_PREFIX}-${node}" sh -lc "$*"
}

list_nodes_by_prefix() {
  local prefix="$1"
  docker ps --format '{{.Names}}' \
    | grep -E "^${CLAB_PREFIX}-${prefix}" \
    | sed -E "s/^${CLAB_PREFIX}-//" \
    | sort
}

echo "=== Resilience Post-Check (Firewall + Spine/Leaf + Bond Hosts) ==="

# 1) Firewall Ring1 static routes must exist after any restore cycle.
if run_node "firewall-01" "ip -4 route show 192.168.0.0/16 | grep -Eq 'via 192.168.1.252 dev eth1( |$)'"; then
  ok "firewall-01 has Ring1 transit route via leaf-01"
else
  ko "firewall-01 missing Ring1 transit route (192.168.0.0/16 via 192.168.1.252 dev eth1)"
fi

if run_node "firewall-02" "ip -4 route show 192.168.0.0/16 | grep -Eq 'via 192.168.1.253 dev eth1( |$)'"; then
  ok "firewall-02 has Ring1 transit route via leaf-02"
else
  ko "firewall-02 missing Ring1 transit route (192.168.0.0/16 via 192.168.1.253 dev eth1)"
fi

# 2) Keepalived should run on both firewalls and VIP should be owned by exactly one.
if run_node "firewall-01" "ps aux | grep -q '[k]eepalived'"; then
  ok "firewall-01 keepalived is running"
else
  ko "firewall-01 keepalived is not running"
fi

if run_node "firewall-02" "ps aux | grep -q '[k]eepalived'"; then
  ok "firewall-02 keepalived is running"
else
  ko "firewall-02 keepalived is not running"
fi

vip_owner_count=0
if run_node "firewall-01" "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
  vip_owner_count=$((vip_owner_count + 1))
fi
if run_node "firewall-02" "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
  vip_owner_count=$((vip_owner_count + 1))
fi

if (( vip_owner_count == 1 )); then
  ok "Ring1 VIP (192.168.1.254/24) has exactly one owner"
else
  ko "Ring1 VIP ownership is invalid (owners=$vip_owner_count, expected=1)"
fi

# 3) Spine BGP summary should show at least one Established session.
while read -r spine; do
  [[ -n "$spine" ]] || continue
  if run_node "$spine" "vtysh -c 'show bgp summary json' 2>/dev/null | grep -q 'Established'"; then
    ok "$spine has Established BGP sessions"
  else
    ko "$spine has no Established BGP sessions"
  fi
done < <(list_nodes_by_prefix 'spine-')

# 4) Border leaf uplinks should be operational (eth1/eth2 toward spines).
while read -r leaf; do
  [[ -n "$leaf" ]] || continue
  for uplink in eth1 eth2; do
    if run_node "$leaf" "ip -o link show dev $uplink | grep -Eq 'state (UP|UNKNOWN)'"; then
      ok "$leaf:$uplink is operational"
    else
      ko "$leaf:$uplink is not operational"
    fi
  done
done < <(list_nodes_by_prefix 'leaf-')

# 5) Dual-homed hosts using bond0 should report an active/up bond.
while read -r server; do
  [[ -n "$server" ]] || continue

  if ! run_node "$server" "test -f /proc/net/bonding/bond0"; then
    continue
  fi

  if run_node "$server" "grep -q '^MII Status: up' /proc/net/bonding/bond0"; then
    ok "$server bond0 MII status is up"
  else
    ko "$server bond0 MII status is not up"
  fi

  if run_node "$server" "grep -q '^Currently Active Slave: ' /proc/net/bonding/bond0 && ! grep -q '^Currently Active Slave: None' /proc/net/bonding/bond0"; then
    ok "$server has an active bond0 slave"
  else
    ko "$server has no active bond0 slave"
  fi
done < <(list_nodes_by_prefix 'server-')

echo "Passed: $pass"
echo "Failed: $fail"

if (( fail > 0 )); then
  exit 1
fi
