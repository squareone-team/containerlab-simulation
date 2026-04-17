#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

run_test() {
  local label="$1"
  local script="$2"

  echo ""
  echo "============================================================"
  echo "Running: $label"
  echo "Script : $script"
  echo "============================================================"

  if bash "$script"; then
    echo "[PASS] $label"
    return 0
  fi

  echo "[FAIL] $label"
  return 1
}

overall_fail=0

run_test "Firewall Policy Validation" "$ROOT_DIR/firewall_policy_validation.sh" || overall_fail=1
run_test "Firewall In-Path Validation" "$ROOT_DIR/firewall_inpath_validation.sh" || overall_fail=1
run_test "Firewall End-to-End Validation" "$ROOT_DIR/firewall_e2e_validation.sh" || overall_fail=1

echo ""
echo "============================================================"
echo "Firewall Validation Suite Summary"
echo "============================================================"
if [[ $overall_fail -eq 0 ]]; then
  echo "All firewall validation scripts passed."
  exit 0
fi

echo "One or more firewall validation scripts failed."
exit 1
