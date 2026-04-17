#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="${LAB_NAME:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB_NAME}-"
SYSLOG="${CLAB_PREFIX}syslog-server"
# Test from nodes that can reach 192.168.50.70 (admin subnet)
# Other fabric nodes (leaf-01+, spine-*) are in different VRF; intentional isolation
SOURCES=("${CLAB_PREFIX}server-admin-01")
TOKEN="RING6_VERIFY_$(date +%s)"

echo "=== Ring 6 (Reliable Logging) Deep Verification ==="

# 1. Protocol Check (The v2.0 Requirement)
echo "[1/3] Verifying Syslog Server is listening on TCP/514..."
if docker exec "$SYSLOG" netstat -tln | grep -q ":514 "; then
  echo "  [PASS] TCP 514 Listener found."
else
  echo "  [FAIL] Syslog server is NOT listening on TCP 514 (Check rsyslog.conf)" >&2
  exit 1
fi

# 2. Multi-Node Injection
for NODE in "${SOURCES[@]}"; do
  echo "[2/3] Injecting test log from $NODE..."
  if ! docker exec "$NODE" logger -t "T3-TEST" "$TOKEN-$NODE"; then
     echo "  [FAIL] Could not run logger on $NODE" >&2
     exit 1
  fi
done

# 3. Persistence Check
echo "[3/3] Waiting for logs to traverse the fabric to $SYSLOG..."
for NODE in "${SOURCES[@]}"; do
  SUCCESS=false
  for _ in $(seq 1 15); do
    if docker exec "$SYSLOG" grep -q "$TOKEN-$NODE" /var/log/messages 2>/dev/null || \
       docker exec "$SYSLOG" grep -q "$TOKEN-$NODE" /var/log/syslog 2>/dev/null; then
      echo "  [PASS] Found log from $NODE"
      SUCCESS=true
      break
    fi
    sleep 1
  done
  
  if [ "$SUCCESS" = false ]; then
    echo "  [FAIL] Log from $NODE never arrived at central server." >&2
    exit 1
  fi
done

echo "=== RING 6 VERIFIED SUCCESSFULLY ==="
exit 0