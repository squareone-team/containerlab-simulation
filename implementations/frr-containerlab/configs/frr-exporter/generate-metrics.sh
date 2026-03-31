#!/bin/sh
set -eu

LAB_NAME="${LAB_NAME:-esi-datacenter}"
OUT_FILE="/srv/www/metrics/metrics"

pod_for_node() {
  case "$1" in
    leaf-01|leaf-02) echo "border" ;;
    leaf-03|leaf-04) echo "admin" ;;
    leaf-05|leaf-06) echo "hpc" ;;
    leaf-07|leaf-08) echo "storage" ;;
    leaf-09|leaf-10) echo "student" ;;
    spine-01|spine-02) echo "core" ;;
    isp-router-*) echo "edge" ;;
    internet-router-*) echo "internet" ;;
    *) echo "other" ;;
  esac
}

peer_role_for() {
  node="$1"
  peer="$2"

  case "$node" in
    leaf-01|leaf-02)
      case "$peer" in
        203.0.113.*|203.0.114.*|198.18.*) echo "isp" ;;
        10.*) echo "spine" ;;
        *) echo "peer" ;;
      esac
      ;;
    leaf-*) echo "spine" ;;
    spine-*) echo "leaf" ;;
    *) echo "peer" ;;
  esac
}

route_count_for_vrf() {
  container="$1"
  vrf="$2"

  json_out="$(docker exec "$container" vtysh -c "show ip route vrf $vrf json" 2>/dev/null || true)"
  if [ -n "$json_out" ]; then
    count="$(printf '%s' "$json_out" | jq -r 'if type=="object" then (keys|length) else 0 end' 2>/dev/null || echo 0)"
    case "$count" in
      ''|null|*[!0-9]*) count=0 ;;
    esac
    printf '%s\n' "$count"
    return
  fi

  text_out="$(docker exec "$container" vtysh -c "show ip route vrf $vrf" 2>/dev/null || true)"
  if [ -n "$text_out" ]; then
    printf '%s\n' "$text_out" | grep -Ec '^[A-Z\*][^: ]' || true
    return
  fi

  echo 0
}

leaf_uplink_up() {
  container="$1"
  iface="$2"

  if docker exec "$container" sh -lc "[ -r /sys/class/net/$iface/operstate ] && grep -q up /sys/class/net/$iface/operstate" >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

leaf_has_established_bgp() {
  container="$1"

  summary="$(docker exec "$container" vtysh -c 'show bgp summary json' 2>/dev/null || true)"
  if [ -z "$summary" ]; then
    echo 0
    return
  fi

  established="$(printf '%s' "$summary" | jq -r '[.ipv4Unicast.peers // {} | to_entries[] | select(.value.state=="Established")] | length' 2>/dev/null || echo 0)"
  case "$established" in
    ''|null|*[!0-9]*) established=0 ;;
  esac

  if [ "$established" -gt 0 ]; then
    echo 1
  else
    echo 0
  fi
}

emit_expected_vni_metrics() {
  node="$1"
  pod="$2"
  container="$3"
  tmp_file="$4"

  evpn_text="$(docker exec "$container" vtysh -c 'show evpn vni' 2>/dev/null || true)"
  [ -n "$evpn_text" ] || return 0

  emit_vni() {
    vni="$1"
    segment="$2"
    vrf="$3"
    if printf '%s\n' "$evpn_text" | grep -Eq "(^|[^0-9])${vni}([^0-9]|$)"; then
      state=1
    else
      state=0
    fi
    printf 'frr_evpn_vni_up{node="%s",vni="%s",segment="%s",vrf="%s",pod="%s"} %s\n' "$node" "$vni" "$segment" "$vrf" "$pod" "$state" >> "$tmp_file"
  }

  case "$node" in
    leaf-01)
      emit_vni "10090" "BAC-ORIENT" "VRF-ORIENTATION"
      emit_vni "10100" "DMZ-WEB" "VRF-PUBLIC"
      emit_vni "10120" "WIFI-CTRL-MGMT" "VRF-WIFI-CTRL"
      ;;
    leaf-03)
      emit_vni "10030" "LMS-STAFF" "VRF-STAFF"
      emit_vni "10040" "SERVICES-WEB" "VRF-STAFF"
      emit_vni "10050" "CORE-INFRA" "VRF-STAFF"
      emit_vni "10060" "HR-FINANCE" "VRF-ADMINISTRATION"
      ;;
    leaf-05)
      emit_vni "10070" "AI-GPU" "VRF-STAFF"
      ;;
    leaf-07)
      emit_vni "10080" "STORAGE-SAN" "VRF-STAFF"
      ;;
    leaf-09)
      emit_vni "10010" "STUDENT-TP" "VRF-PEDAGOGY"
      emit_vni "10020" "STUDENT-PROJ" "VRF-PEDAGOGY"
      ;;
  esac
}

emit_vrf_route_metrics() {
  node="$1"
  pod="$2"
  container="$3"
  tmp_file="$4"

  case "$node" in
    leaf-01)
      for vrf in VRF-PUBLIC VRF-ORIENTATION VRF-WIFI-CTRL; do
        count="$(route_count_for_vrf "$container" "$vrf")"
        printf 'frr_vrf_route_count{node="%s",vrf="%s",pod="%s"} %s\n' "$node" "$vrf" "$pod" "$count" >> "$tmp_file"
      done
      ;;
    leaf-03)
      for vrf in VRF-STAFF VRF-ADMINISTRATION; do
        count="$(route_count_for_vrf "$container" "$vrf")"
        printf 'frr_vrf_route_count{node="%s",vrf="%s",pod="%s"} %s\n' "$node" "$vrf" "$pod" "$count" >> "$tmp_file"
      done
      ;;
    leaf-05|leaf-07)
      count="$(route_count_for_vrf "$container" "VRF-STAFF")"
      printf 'frr_vrf_route_count{node="%s",vrf="VRF-STAFF",pod="%s"} %s\n' "$node" "$pod" "$count" >> "$tmp_file"
      ;;
    leaf-09)
      count="$(route_count_for_vrf "$container" "VRF-PEDAGOGY")"
      printf 'frr_vrf_route_count{node="%s",vrf="VRF-PEDAGOGY",pod="%s"} %s\n' "$node" "$pod" "$count" >> "$tmp_file"
      ;;
  esac
}

emit_pod_health() {
  pod="$1"
  leaf_a="$2"
  leaf_b="$3"
  tmp_file="$4"

  score_total=0
  score_max=6

  for leaf in "$leaf_a" "$leaf_b"; do
    container="clab-${LAB_NAME}-${leaf}"
    if docker ps --format '{{.Names}}' | grep -qx "$container"; then
      up1="$(leaf_uplink_up "$container" eth1)"
      up2="$(leaf_uplink_up "$container" eth2)"
      bgp="$(leaf_has_established_bgp "$container")"
      score_total=$((score_total + up1 + up2 + bgp))
    fi
  done

  score="$(awk -v s="$score_total" -v m="$score_max" 'BEGIN { if (m==0) {print 0} else { printf "%.2f", s/m } }')"
  printf 'fabric_pod_health_score{pod="%s"} %s\n' "$pod" "$score" >> "$tmp_file"
}

generate_metrics() {
  tmp_file="/tmp/metrics.$$"
  start_ts="$(date +%s)"

  {
    echo "# HELP frr_bgp_session_up Dynamic BGP session state from live FRR nodes."
    echo "# TYPE frr_bgp_session_up gauge"
    echo "# HELP frr_bgp_prefixes_received Dynamic received BGP prefixes from live FRR nodes."
    echo "# TYPE frr_bgp_prefixes_received gauge"
    echo "# HELP frr_vrf_route_count Dynamic active route count per VRF from live FRR nodes."
    echo "# TYPE frr_vrf_route_count gauge"
    echo "# HELP frr_evpn_vni_up Dynamic EVPN VNI operational state from live FRR nodes."
    echo "# TYPE frr_evpn_vni_up gauge"
    echo "# HELP frr_node_cpu_utilization_percent Dynamic container CPU usage percentage for FRR nodes."
    echo "# TYPE frr_node_cpu_utilization_percent gauge"
    echo "# HELP frr_node_memory_utilization_percent Dynamic container memory usage percentage for FRR nodes."
    echo "# TYPE frr_node_memory_utilization_percent gauge"
    echo "# HELP fabric_uplink_status Dynamic leaf uplink state to spine nodes (1=up, 0=down)."
    echo "# TYPE fabric_uplink_status gauge"
    echo "# HELP fabric_pod_health_score Dynamic pod health score from 0 to 1 based on uplink and BGP readiness."
    echo "# TYPE fabric_pod_health_score gauge"
    echo "# HELP frr_exporter_target_containers Number of FRR containers discovered for dynamic scrape."
    echo "# TYPE frr_exporter_target_containers gauge"
    echo "# HELP frr_exporter_last_scrape_success Last scrape generation status (1=success, 0=failure)."
    echo "# TYPE frr_exporter_last_scrape_success gauge"
    echo "# HELP frr_exporter_scrape_duration_seconds Dynamic scrape generation duration in seconds."
    echo "# TYPE frr_exporter_scrape_duration_seconds gauge"
  } > "$tmp_file"

  frr_containers="$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /^frrouting\/frr/ {print $1}' || true)"
  targets_count="$(printf '%s\n' "$frr_containers" | awk 'NF>0 {n++} END {print n+0}')"

  printf 'frr_exporter_target_containers %s\n' "$targets_count" >> "$tmp_file"

  if [ "$targets_count" -eq 0 ]; then
    printf 'frr_exporter_last_scrape_success 0\n' >> "$tmp_file"
    duration="$(awk -v s="$start_ts" -v e="$(date +%s)" 'BEGIN { printf "%.3f", e-s }')"
    printf 'frr_exporter_scrape_duration_seconds %s\n' "$duration" >> "$tmp_file"
    mv "$tmp_file" "$OUT_FILE"
    return
  fi

  printf '%s\n' "$frr_containers" | while IFS= read -r container; do
    [ -n "$container" ] || continue
    node="${container#clab-${LAB_NAME}-}"
    pod="$(pod_for_node "$node")"

    stats="$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$container" 2>/dev/null || true)"
    cpu_pct="$(printf '%s' "$stats" | awk '{gsub("%", "", $1); if ($1=="") print 0; else print $1}')"
    mem_pct="$(printf '%s' "$stats" | awk '{gsub("%", "", $2); if ($2=="") print 0; else print $2}')"
    printf 'frr_node_cpu_utilization_percent{node="%s",role="%s",pod="%s"} %s\n' "$node" "$(echo "$node" | sed 's/-.*//')" "$pod" "$cpu_pct" >> "$tmp_file"
    printf 'frr_node_memory_utilization_percent{node="%s",role="%s",pod="%s"} %s\n' "$node" "$(echo "$node" | sed 's/-.*//')" "$pod" "$mem_pct" >> "$tmp_file"

    bgp_json="$(docker exec "$container" vtysh -c 'show bgp summary json' 2>/dev/null || true)"
    if [ -n "$bgp_json" ] && printf '%s' "$bgp_json" | jq . >/dev/null 2>&1; then
      for family in "ipv4Unicast ipv4_unicast" "l2VpnEvpn l2vpn_evpn"; do
        family_key="${family%% *}"
        family_label="${family##* }"

        printf '%s' "$bgp_json" | jq -r --arg f "$family_key" '.[$f].peers // {} | to_entries[] | [.key, (.value.state // "Unknown"), ((.value.pfxRcd // 0)|tostring)] | @tsv' 2>/dev/null | while IFS="$(printf '\t')" read -r peer state pfx; do
          [ -n "$peer" ] || continue
          if [ "$state" = "Established" ]; then
            up=1
          else
            up=0
          fi
          role="$(peer_role_for "$node" "$peer")"
          case "$pfx" in
            ''|null|*[!0-9]*) pfx=0 ;;
          esac
          printf 'frr_bgp_session_up{node="%s",peer="%s",peer_role="%s",pod="%s"} %s\n' "$node" "$peer" "$role" "$pod" "$up" >> "$tmp_file"
          printf 'frr_bgp_prefixes_received{node="%s",peer="%s",afi_safi="%s",pod="%s"} %s\n' "$node" "$peer" "$family_label" "$pod" "$pfx" >> "$tmp_file"
        done
      done
    fi

    emit_vrf_route_metrics "$node" "$pod" "$container" "$tmp_file"
    emit_expected_vni_metrics "$node" "$pod" "$container" "$tmp_file"

    case "$node" in
      leaf-*)
        up1="$(leaf_uplink_up "$container" eth1)"
        up2="$(leaf_uplink_up "$container" eth2)"
        printf 'fabric_uplink_status{node="%s",uplink="eth1",spine="spine-01"} %s\n' "$node" "$up1" >> "$tmp_file"
        printf 'fabric_uplink_status{node="%s",uplink="eth2",spine="spine-02"} %s\n' "$node" "$up2" >> "$tmp_file"
        ;;
    esac
  done

  emit_pod_health "border" "leaf-01" "leaf-02" "$tmp_file"
  emit_pod_health "admin" "leaf-03" "leaf-04" "$tmp_file"
  emit_pod_health "hpc" "leaf-05" "leaf-06" "$tmp_file"
  emit_pod_health "storage" "leaf-07" "leaf-08" "$tmp_file"
  emit_pod_health "student" "leaf-09" "leaf-10" "$tmp_file"

  printf 'frr_exporter_last_scrape_success 1\n' >> "$tmp_file"
  duration="$(awk -v s="$start_ts" -v e="$(date +%s)" 'BEGIN { printf "%.3f", e-s }')"
  printf 'frr_exporter_scrape_duration_seconds %s\n' "$duration" >> "$tmp_file"

  mv "$tmp_file" "$OUT_FILE"
}

while true; do
  generate_metrics
  sleep 15
done
