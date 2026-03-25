# Add this to your tests/t4-verify.sh
C="docker exec clab-esi-datacenter"

# NTP server is stratum 2
$C-ntp-server chronyc tracking | grep -q "Stratum : 2" \
  && echo "[PASS] ntp-server synced at stratum 2" \
  || echo "[FAIL] ntp-server not synced"

# Spine nodes synced to our server
$C-spine-01 chronyc tracking | grep -q "Reference ID.*192.168.50.20\|Stratum : 3" \
  && echo "[PASS] spine-01 syncing from ntp-server" \
  || echo "[FAIL] spine-01 not synced"

# Clock skew under 1 second on all FRR nodes (forensic requirement)
for NODE in spine-01 spine-02 leaf-01 leaf-03 leaf-05 leaf-07 leaf-09; do
  OFFSET=$($C-$NODE chronyc tracking 2>/dev/null | grep "System time" \
    | grep -oE '[0-9]+\.[0-9]+' | head -1)
  awk -v o="${OFFSET:-999}" 'BEGIN { exit (o+0 < 1.0) ? 0 : 1 }' \
    && echo "[PASS] $NODE clock offset ${OFFSET}s < 1s" \
    || echo "[FAIL] $NODE clock offset ${OFFSET}s too large"
done