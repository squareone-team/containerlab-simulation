#!/bin/sh
# Ring 1 HA Firewall validation script (Task 1)
# - Ping VIP from leaf-01
# - Verify Cluster 2 (Admin) can initiate to Cluster 1
# - Verify Cluster 1 cannot initiate back to Cluster 2

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

test_vip_ping_from_leaf01() {
    run_in_container "leaf-01" "ping -c 2 -W 2 192.168.1.254 >/dev/null"
}

test_admin_to_general_allowed() {
    run_in_container "server-student-01" "pkill nc >/dev/null 2>&1 || true"
    run_in_container "server-student-01" "nc -l -p 9100 >/tmp/admin_to_general.log 2>&1 &"
    sleep 1

    run_in_container "server-admin-01" "echo admin-init | nc -w 3 192.168.10.10 9100 >/dev/null"
}

test_general_to_admin_blocked() {
    run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true"
    run_in_container "server-admin-01" "nc -l -p 9100 >/tmp/general_to_admin.log 2>&1 &"
    sleep 1

    if run_in_container "server-student-01" "echo student-init | nc -w 3 192.168.50.10 9100 >/dev/null"; then
        return 1
    fi

    return 0
}

cleanup() {
    run_in_container "server-student-01" "pkill nc >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "=== Ring 1 HA Firewall Tests ==="
assert_ok "leaf-01 can ping VIP 192.168.1.254" test_vip_ping_from_leaf01
assert_ok "Cluster 2 Admin can initiate to Cluster 1" test_admin_to_general_allowed
assert_ok "Cluster 1 cannot initiate to Cluster 2" test_general_to_admin_blocked

echo "==============================="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[ "${FAIL}" -eq 0 ]
