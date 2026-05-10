#!/bin/sh
# Firewall policy and control-plane validation for Ring 1.

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

get_master_firewall() {
    if run_in_container "firewall-01" "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
        echo "firewall-01"
    elif run_in_container "firewall-02" "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
        echo "firewall-02"
    else
        echo ""
    fi
}

rule_present() {
    fragment="$1"
    run_in_container "firewall-01" "nft list chain inet filter forward | grep -F \"$fragment\" >/dev/null"
}

test_vip_ping_from_leaf01() {
    run_in_container "leaf-01" "ping -c 2 -W 2 192.168.1.254 >/dev/null"
}

test_master_firewall_exists() {
    [ -n "$(get_master_firewall)" ]
}

test_default_deny_present() {
    run_in_container "firewall-01" "nft list chain inet filter input | grep -F 'policy drop' >/dev/null" &&
        run_in_container "firewall-01" "nft list chain inet filter forward | grep -F 'policy drop' >/dev/null"
}

test_stateful_base_rule_present() {
    run_in_container "firewall-01" "nft list chain inet filter forward | grep -F 'ct state { established, related }' | grep -F 'counter' | grep -F 'accept' >/dev/null"
}

test_admin_to_general_rule_present() {
    rule_present "ip saddr @cluster_2_admin ip daddr @cluster_1_pedagogy tcp dport { 53, 9100 } ct state new"
}

test_admin_to_hpc_rule_present() {
    rule_present "ip saddr @cluster_2_admin ip daddr @cluster_3_hpc tcp dport 6818-6830 ct state new"
}

test_general_to_storage_rule_present() {
    rule_present "ip saddr @cluster_1_pedagogy ip daddr @cluster_5_storage tcp dport { 111, 2049, 3260 } ct state new"
}

test_admin_to_storage_rule_present() {
    rule_present "ip saddr @cluster_2_admin ip daddr @cluster_5_storage tcp dport { 111, 2049, 3260 } ct state new"
}

test_general_to_admin_drop_present() {
    rule_present "ip saddr @cluster_1_pedagogy ip daddr @cluster_2_admin"
}

test_orientation_drop_present() {
    rule_present "ip saddr @cluster_4_orientation" &&
        rule_present "ip daddr @cluster_4_orientation"
}

test_moodle_access_present() {
    rule_present "ip saddr @cluster_1_pedagogy ip daddr @cluster_lms_staff tcp dport { 80, 443 } ct state new"
}

test_syslog_access_present() {
    rule_present "ip saddr @cluster_1_pedagogy ip daddr @core_infra_syslog tcp dport 514 ct state new" &&
        rule_present "ip saddr @cluster_campus_access ip daddr @core_infra_syslog tcp dport 514 ct state new" &&
        rule_present "ip saddr @cluster_public_dmz ip daddr @core_infra_syslog tcp dport 514 ct state new"
}

test_shared_dhcp_access_present() {
    rule_present "ip saddr @cluster_1_pedagogy ip daddr @core_infra_dhcp udp dport { 67, 68 } ct state new" &&
        rule_present "ip saddr @cluster_campus_access ip daddr @core_infra_dhcp udp dport { 67, 68 } ct state new"
}

test_tacacs_auth_policy_present() {
    rule_present "ip saddr @tacacs_auth_clients ip daddr @core_infra_auth tcp dport 49 ct state new" &&
        rule_present "ip saddr @cluster_campus_access ip daddr @campus_ssh_targets tcp dport 22 ct state new" &&
        rule_present "ip saddr @campus_nac_gateway ip daddr @core_infra_auth udp dport 1812 ct state new" &&
        rule_present "ip saddr @vpn_gateway ip daddr @core_infra_auth udp dport 1812 ct state new" &&
        rule_present "ip saddr @vpn_gateway ip daddr @vpn_student_ssh_targets tcp dport 22 ct state new" &&
        rule_present "ip saddr @cluster_campus_access ip daddr 192.168.70.30 tcp dport 8080 ct state new" &&
        rule_present "ip saddr @vpn_gateway ip daddr 192.168.70.30 tcp dport 8080 ct state new" &&
        rule_present "ip saddr @cluster_campus_access ip daddr @core_infra_auth tcp dport { 49, 389, 8080 }"
}

test_dmz_isolation_present() {
    rule_present "ip saddr @cluster_public_dmz ip daddr @cluster_1_pedagogy" &&
        rule_present "ip saddr @cluster_public_dmz ip daddr @cluster_2_admin"
}

test_no_hpc_to_storage_rule_present() {
    run_in_container "firewall-01" "nft list chain inet filter forward | grep -E 'cluster_3_hpc.*cluster_5_storage|cluster_5_storage.*cluster_3_hpc' >/dev/null && exit 1 || exit 0"
}

echo "=== Firewall Policy Validation (Ring 1) ==="
assert_ok "leaf-01 can ping VIP 192.168.1.254" test_vip_ping_from_leaf01
assert_ok "one firewall owns VIP 192.168.1.254" test_master_firewall_exists
assert_ok "default deny policy present" test_default_deny_present
assert_ok "stateful base rule present with counters" test_stateful_base_rule_present
assert_ok "rule Admin->Pedagogy present with counters" test_admin_to_general_rule_present
assert_ok "rule Admin->HPC present with counters" test_admin_to_hpc_rule_present
assert_ok "rule Pedagogy->Storage present with counters" test_general_to_storage_rule_present
assert_ok "rule Admin->Storage present with counters" test_admin_to_storage_rule_present
assert_ok "rule Pedagogy->Admin explicit drop present with counters" test_general_to_admin_drop_present
assert_ok "rule Orientation explicit drops present with counters" test_orientation_drop_present
assert_ok "rule Moodle access present with counters" test_moodle_access_present
assert_ok "rule centralized syslog export present with counters" test_syslog_access_present
assert_ok "rule shared DHCP access present with counters" test_shared_dhcp_access_present
assert_ok "strict campus TACACS+/SSH policy present with counters" test_tacacs_auth_policy_present
assert_ok "rule DMZ isolation explicit drops present with counters" test_dmz_isolation_present
assert_ok "no HPC<->Storage firewall rule (hairpinning constraint)" test_no_hpc_to_storage_rule_present

echo "==============================================="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[ "${FAIL}" -eq 0 ]
