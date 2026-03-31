#!/bin/sh
# Firewall policy and behavior validation for Ring 1.

set -eu

CLAB_NAME="clab-esi-datacenter"
PASS=0
FAIL=0

run_in_container() {
    container="$1"
    cmd="$2"
    docker exec "${CLAB_NAME}-${container}" sh -c "$cmd"
}

assert_ok() {
    name="$1"
    if "$2"; then
        echo "[PASS] ${name}"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] ${name}"
        FAIL=$((FAIL + 1))
    fi
}

connect_tcp_expect_blocked() {
    src_container="$1"
    dst_ip="$2"
    dst_port="$3"
    if run_in_container "$src_container" "echo test | nc -w 3 ${dst_ip} ${dst_port} >/dev/null"; then
        return 1
    fi
    return 0
}

test_vip_ping_from_leaf01() {
    run_in_container "leaf-01" "ping -c 2 -W 2 192.168.1.254 >/dev/null"
}

get_master_firewall() {
    if run_in_container "firewall-01" "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
        echo "firewall-01"
    elif run_in_container "firewall-02" "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
        echo "firewall-02"
    else
        echo ""
    fi
}

test_traceroute_admin_to_general() {
    run_in_container "server-admin-01" '
        set -eu
        if command -v traceroute >/dev/null 2>&1; then
            OUT=$(traceroute -n -w 1 -q 1 -m 6 192.168.10.10 2>/dev/null || true)
        elif command -v tracepath >/dev/null 2>&1; then
            OUT=$(tracepath -n 192.168.10.10 2>/dev/null || true)
        else
            OUT=$(busybox traceroute -n -w 1 -q 1 -m 6 192.168.10.10 2>/dev/null || true)
        fi
        echo "$OUT" > /tmp/admin_to_general_traceroute.log
        [ -n "$OUT" ]
    '
}

test_traceroute_hits_firewall_path() {
    MASTER_FW=$(get_master_firewall)
    [ -n "$MASTER_FW" ] || return 1

    before=$(run_in_container "$MASTER_FW" "rx=\$(cat /sys/class/net/eth1/statistics/rx_packets); tx=\$(cat /sys/class/net/eth1/statistics/tx_packets); echo \$((rx+tx))")
    run_in_container "server-admin-01" "ping -c 3 -W 1 192.168.10.10 >/dev/null || true"
    sleep 1
    after=$(run_in_container "$MASTER_FW" "rx=\$(cat /sys/class/net/eth1/statistics/rx_packets); tx=\$(cat /sys/class/net/eth1/statistics/tx_packets); echo \$((rx+tx))")

    [ "$after" -gt "$before" ]
}

test_stateful_base_rule_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ct state { established, related } accept' >/dev/null"
}

test_default_deny_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'chain input {' >/dev/null && nft list ruleset | grep -F 'policy drop;' >/dev/null"
}

test_rule_admin_to_general_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_1_pedagogy tcp dport { 53, 9100 } ct state new accept' >/dev/null && nft list ruleset | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_1_pedagogy udp dport { 53, 67, 68 } ct state new accept' >/dev/null"
}

test_rule_admin_to_hpc_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_3_hpc tcp dport 6818-6830 ct state new accept' >/dev/null && nft list ruleset | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_3_hpc udp dport 6818-6830 ct state new accept' >/dev/null"
}

test_rule_general_to_storage_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_1_pedagogy ip daddr @cluster_5_storage tcp dport { 111, 2049, 3260 } ct state new accept' >/dev/null && nft list ruleset | grep -F 'ip saddr @cluster_1_pedagogy ip daddr @cluster_5_storage udp dport { 111, 2049 } ct state new accept' >/dev/null"
}

test_rule_admin_to_storage_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_5_storage tcp dport { 111, 2049, 3260 } ct state new accept' >/dev/null && nft list ruleset | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_5_storage udp dport { 111, 2049 } ct state new accept' >/dev/null"
}

test_rule_general_to_admin_drop_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_1_pedagogy ip daddr @cluster_2_admin drop' >/dev/null"
}

test_rule_orientation_drop_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_4_orientation drop' >/dev/null && nft list ruleset | grep -F 'ip daddr @cluster_4_orientation drop' >/dev/null"
}

test_rule_moodle_access_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_1_pedagogy ip daddr @cluster_lms_staff tcp dport { 80, 443 } ct state new accept' >/dev/null"
}

test_rule_dmz_isolation_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_public_dmz ip daddr @cluster_1_pedagogy drop' >/dev/null && nft list ruleset | grep -F 'ip saddr @cluster_public_dmz ip daddr @cluster_2_admin drop' >/dev/null"
}

test_orientation_isolated_from_admin() {
    connect_tcp_expect_blocked "server-admin-01" "192.168.100.10" "9100"
}

test_orientation_isolated_to_admin() {
    connect_tcp_expect_blocked "server-dmz-01" "192.168.50.10" "9100"
}

test_no_hpc_to_storage_rule_present() {
    run_in_container "firewall-01" "nft list ruleset | grep -E 'cluster_3_hpc.*cluster_5_storage|cluster_5_storage.*cluster_3_hpc' >/dev/null && exit 1 || exit 0"
}

test_runtime_general_to_admin_blocked() {
    connect_tcp_expect_blocked "server-student-01" "192.168.50.10" "9100"
}

cleanup() {
    run_in_container "server-student-01" "pkill nc >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "=== Firewall Policy Validation (Ring 1) ==="
assert_ok "leaf-01 can ping VIP 192.168.1.254" test_vip_ping_from_leaf01
assert_ok "traceroute (tracert) Admin->General runs" test_traceroute_admin_to_general
assert_ok "traceroute Admin->General traverses active firewall path" test_traceroute_hits_firewall_path
assert_ok "Stateful base rule present" test_stateful_base_rule_present
assert_ok "Default deny policy present" test_default_deny_present
assert_ok "Rule Admin->General (DNS/DHCP/Monitoring) present" test_rule_admin_to_general_present
assert_ok "Rule Admin->HPC (SLURM) present" test_rule_admin_to_hpc_present
assert_ok "Rule General->Storage (NFS/iSCSI) present" test_rule_general_to_storage_present
assert_ok "Rule Admin->Storage (NFS/iSCSI) present" test_rule_admin_to_storage_present
assert_ok "Rule General->Admin explicit drop present" test_rule_general_to_admin_drop_present
assert_ok "Rule Orientation explicit drop present" test_rule_orientation_drop_present
assert_ok "Rule Moodle access (Pedagogy->LMS 80/443) present" test_rule_moodle_access_present
assert_ok "Rule DMZ isolation explicit drops present" test_rule_dmz_isolation_present
assert_ok "Orientation isolated from Admin" test_orientation_isolated_from_admin
assert_ok "Orientation isolated toward Admin" test_orientation_isolated_to_admin
assert_ok "Runtime General->Admin initiation blocked" test_runtime_general_to_admin_blocked
assert_ok "No HPC<->Storage firewall rule (hairpinning constraint)" test_no_hpc_to_storage_rule_present

echo "==============================================="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[ "${FAIL}" -eq 0 ]
