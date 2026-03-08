#!/usr/bin/env python3
"""
verify_lightweight_lab.py — ESI Datacenter Lightweight (Arista + FRR) Validation
=================================================================================
Validates the hybrid EVPN/VXLAN fabric where:
  - Spines + Leaves run Arista cEOS  (validated via EOS Cli)
  - Borders run FRR                  (validated via vtysh)
  - Servers run Alpine               (validated via docker exec)

Usage:
    python3 verify_lightweight_lab.py
    python3 verify_lightweight_lab.py --section bgp
    python3 verify_lightweight_lab.py --section ping
    python3 verify_lightweight_lab.py --node spine-01
    python3 verify_lightweight_lab.py --verbose
    python3 verify_lightweight_lab.py --wait 30
"""

import re
import subprocess
import sys
import argparse
import time
from dataclasses import dataclass, field

# ── ANSI colours ─────────────────────────────────────────────
GREEN  = "\033[0;32m"
RED    = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
BOLD   = "\033[1m"
NC     = "\033[0m"

def ok(msg):     print(f"{GREEN}[PASS]{NC} {msg}")
def fail(msg):   print(f"{RED}[FAIL]{NC} {msg}")
def warn(msg):   print(f"{YELLOW}[WARN]{NC} {msg}")
def info(msg):   print(f"{CYAN}[INFO]{NC} {msg}")
def header(msg): print(f"\n{BOLD}── {msg} ──{NC}")


# ── Lab constants ─────────────────────────────────────────────
LAB_PREFIX = "clab-esi-lightweight"

# Node types: "eos" = Arista cEOS, "frr" = FRRouting
NODES = {
    "spine-01":  {"asn": 65000, "loopback": "10.1.0.1",  "type": "eos"},
    "spine-02":  {"asn": 65000, "loopback": "10.1.0.2",  "type": "eos"},
    "leaf-01":   {"asn": 65001, "loopback": "10.1.0.11", "type": "eos"},
    "leaf-02":   {"asn": 65002, "loopback": "10.1.0.12", "type": "eos"},
    "leaf-03":   {"asn": 65003, "loopback": "10.1.0.13", "type": "eos"},
    "leaf-04":   {"asn": 65004, "loopback": "10.1.0.14", "type": "eos"},
    "border-01": {"asn": 65005, "loopback": "10.1.0.21", "type": "frr"},
    "border-02": {"asn": 65005, "loopback": "10.1.0.22", "type": "frr"},
}

# Expected EVPN overlay peers (loopback IPs)
EVPN_OVERLAY_PEERS = {
    "leaf-01":   ["10.1.0.1", "10.1.0.2"],
    "leaf-02":   ["10.1.0.1", "10.1.0.2"],
    "leaf-03":   ["10.1.0.1", "10.1.0.2"],
    "leaf-04":   ["10.1.0.1", "10.1.0.2"],
    "border-01": ["10.1.0.1", "10.1.0.2"],
    "border-02": ["10.1.0.1", "10.1.0.2"],
    "spine-01":  ["10.1.0.11", "10.1.0.12", "10.1.0.13",
                  "10.1.0.14", "10.1.0.21", "10.1.0.22"],
    "spine-02":  ["10.1.0.11", "10.1.0.12", "10.1.0.13",
                  "10.1.0.14", "10.1.0.21", "10.1.0.22"],
}

# Expected VNIs per node
VNI_MEMBERSHIP = {
    "leaf-01":   [10010, 10020, 50001],
    "leaf-02":   [10030, 10040, 50002],
    "leaf-03":   [10050, 10060, 50003],
    "leaf-04":   [10080, 50004],
    "border-01": [50001, 50002, 50003, 50004],
    "border-02": [50001, 50002, 50003, 50004],
}

# ICMP reachability scenarios
PING_SCENARIOS = [
    # ── Intra-VRF (same zone) ──────────────────────────────
    ("server-ped-01", "192.168.20.10", "Pedagogy L2   : ped-01 → ped-02"),
    ("server-res-01", "192.168.40.10", "Research L2   : res-01 → res-02"),
    ("server-svc-01", "192.168.60.10", "Services L2   : svc-01 → svc-02"),
    ("server-ai-01",  "192.168.80.20", "AI L2         : ai-01  → ai-02"),
    # ── Inter-VRF (cross-zone via L3VNI) ─────────────────
    ("server-ped-01", "192.168.30.10", "Cross-VRF     : pedagogy → research"),
    ("server-res-01", "192.168.50.10", "Cross-VRF     : research → services"),
    ("server-svc-01", "192.168.80.10", "Cross-VRF     : services → AI"),
    ("server-ai-01",  "192.168.10.10", "Cross-VRF     : AI       → pedagogy"),
]


@dataclass
class TestResult:
    passed: int = 0
    failed: int = 0
    warned: int = 0
    failures: list = field(default_factory=list)


# ── Helpers ───────────────────────────────────────────────────
def container_name(node: str) -> str:
    return f"{LAB_PREFIX}-{node}"


def eos_exec(node: str, cmd: str, verbose: bool = False) -> tuple:
    """Run an EOS CLI command inside a cEOS container."""
    full_cmd = f"Cli -p 15 -c '{cmd}'"
    docker_cmd = ["docker", "exec", container_name(node), "bash", "-c", full_cmd]
    if verbose:
        info(f"  [{node}] EOS: {cmd}")
    try:
        result = subprocess.run(docker_cmd, capture_output=True, text=True, timeout=15)
        return result.returncode, result.stdout.strip()
    except subprocess.TimeoutExpired:
        return 1, "TIMEOUT"
    except Exception as e:
        return 1, str(e)


def frr_exec(node: str, cmd: str, verbose: bool = False) -> tuple:
    """Run a vtysh command inside an FRR container."""
    docker_cmd = ["docker", "exec", container_name(node), "vtysh", "-c", cmd]
    if verbose:
        info(f"  [{node}] FRR: {cmd}")
    try:
        result = subprocess.run(docker_cmd, capture_output=True, text=True, timeout=15)
        return result.returncode, result.stdout.strip()
    except subprocess.TimeoutExpired:
        return 1, "TIMEOUT"
    except Exception as e:
        return 1, str(e)


def node_exec(node: str, cmd_eos: str, cmd_frr: str, verbose: bool = False) -> tuple:
    """Execute the appropriate command based on node type."""
    ntype = NODES[node]["type"]
    if ntype == "eos":
        return eos_exec(node, cmd_eos, verbose)
    else:
        return frr_exec(node, cmd_frr, verbose)


def docker_exec(container: str, cmd: str, verbose: bool = False) -> tuple:
    """Run a shell command in any container."""
    docker_cmd = ["docker", "exec", f"{LAB_PREFIX}-{container}", "sh", "-c", cmd]
    if verbose:
        info(f"  [{container}] {cmd}")
    try:
        result = subprocess.run(docker_cmd, capture_output=True, text=True, timeout=20)
        return result.returncode, result.stdout.strip()
    except subprocess.TimeoutExpired:
        return 1, "TIMEOUT"
    except Exception as e:
        return 1, str(e)


# FRR neighbor lines: start with IP, field[9] is numeric PfxRcd when Established
_IP_RE = re.compile(r'^\d+\.\d+\.\d+\.\d+')


def frr_count_established(out: str) -> int:
    """Count FRR BGP sessions that are Established (numeric PfxRcd at index 9)."""
    count = 0
    for line in out.split("\n"):
        parts = line.split()
        if len(parts) >= 11 and _IP_RE.match(parts[0]):
            try:
                int(parts[9])
                count += 1
            except ValueError:
                pass
    return count


def is_container_running(node: str) -> bool:
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Running}}", container_name(node)],
        capture_output=True, text=True,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


# ── Section 1 — Container Health ─────────────────────────────
def check_containers(result: TestResult, args) -> None:
    header("Section 1 — Container Health")
    all_containers = list(NODES.keys()) + [
        "server-ped-01", "server-ped-02", "server-res-01", "server-res-02",
        "server-svc-01", "server-svc-02", "server-ai-01", "server-ai-02",
    ]
    nodes = [args.node] if args.node else all_containers
    for node in nodes:
        if is_container_running(node):
            ntype = NODES.get(node, {}).get("type", "linux")
            ok(f"{node} is running ({ntype})")
            result.passed += 1
        else:
            fail(f"{node} container NOT running")
            result.failed += 1
            result.failures.append(f"Container down: {node}")


# ── Section 2 — BGP Underlay ──────────────────────────────────
def check_bgp_underlay(result: TestResult, args) -> None:
    header("Section 2 — BGP Underlay (P2P eBGP)")
    nodes = [args.node] if args.node else list(NODES.keys())
    for node in nodes:
        if not is_container_running(node):
            warn(f"  Skipping {node} — container not running")
            continue
        rc, out = node_exec(node, "show bgp summary", "show bgp summary",
                            verbose=args.verbose)
        if rc != 0:
            fail(f"[{node}] BGP summary command failed")
            result.failed += 1
            result.failures.append(f"BGP underlay unreachable on {node}")
            continue
        # EOS uses "Estab", FRR uses "Established" or state column shows numbers
        ntype = NODES[node]["type"]
        if ntype == "eos":
            established = out.count("Estab")
        else:
            established = frr_count_established(out)

        if established > 0:
            ok(f"[{node}] Underlay BGP — {established} session(s) Established")
            result.passed += 1
        else:
            fail(f"[{node}] No Established underlay BGP sessions")
            result.failed += 1
            result.failures.append(f"No BGP underlay sessions on {node}")
        if args.verbose:
            print(out[:500])


# ── Section 3 — BGP EVPN Overlay ─────────────────────────────
def check_bgp_evpn(result: TestResult, args) -> None:
    header("Section 3 — BGP EVPN Overlay Sessions")
    nodes = [args.node] if args.node else list(NODES.keys())
    for node in nodes:
        if not is_container_running(node):
            warn(f"  Skipping {node} — container not running")
            continue
        rc, out = node_exec(node,
                            "show bgp evpn summary",
                            "show bgp l2vpn evpn summary",
                            verbose=args.verbose)
        if rc != 0:
            fail(f"[{node}] EVPN summary command failed")
            result.failed += 1
            result.failures.append(f"EVPN BGP unreachable on {node}")
            continue
        expected = EVPN_OVERLAY_PEERS.get(node, [])
        missing = [ip for ip in expected if ip not in out]
        if not missing:
            ok(f"[{node}] EVPN overlay — all {len(expected)} peer(s) present")
            result.passed += 1
        else:
            fail(f"[{node}] EVPN peers missing: {missing}")
            result.failed += 1
            result.failures.append(f"EVPN peers missing on {node}: {missing}")

        ntype = NODES[node]["type"]
        if ntype == "eos":
            established = out.count("Estab")
        else:
            established = frr_count_established(out)

        if established == len(expected):
            ok(f"[{node}] All EVPN peers Established ({established}/{len(expected)})")
            result.passed += 1
        else:
            warn(f"[{node}] EVPN peers Established: {established}/{len(expected)}")
            result.warned += 1
        if args.verbose:
            print(out[:500])


# ── Section 4 — VXLAN VNI Membership ─────────────────────────
def check_vxlan_vni(result: TestResult, args) -> None:
    header("Section 4 — VXLAN VNI Membership")
    eligible = {k for k in NODES if k.startswith(("leaf", "border"))}
    nodes = [args.node] if (args.node and args.node in eligible) else list(eligible)
    for node in nodes:
        if not is_container_running(node):
            warn(f"  Skipping {node} — container not running")
            continue
        ntype = NODES[node]["type"]
        expected = VNI_MEMBERSHIP.get(node, [])

        if ntype == "eos":
            rc, out = eos_exec(node, "show vxlan vni", verbose=args.verbose)
            if rc != 0:
                fail(f"[{node}] 'show vxlan vni' failed")
                result.failed += 1
                result.failures.append(f"VXLAN VNI check failed on {node}")
                continue
            missing = [v for v in expected if str(v) not in out]
        else:
            # FRR border: check VXLAN interfaces via ip link
            rc, out = docker_exec(node,
                "ip -d link show type vxlan 2>/dev/null || bridge fdb show 2>/dev/null",
                verbose=args.verbose)
            if rc != 0:
                out = ""
            # Also check via vtysh evpn
            rc2, out2 = frr_exec(node, "show evpn vni", verbose=args.verbose)
            combined = out + "\n" + (out2 if rc2 == 0 else "")
            missing = [v for v in expected if str(v) not in combined]

        if not missing:
            ok(f"[{node}] All VNIs present: {expected}")
            result.passed += 1
        else:
            fail(f"[{node}] Missing VNIs: {missing}")
            result.failed += 1
            result.failures.append(f"Missing VNIs on {node}: {missing}")
        if args.verbose:
            print(out[:400] if out else "  (no output)")


# ── Section 5 — Loopback Reachability ────────────────────────
def check_loopback_reachability(result: TestResult, args) -> None:
    header("Section 5 — Loopback Reachability (Underlay)")
    # From each spine, ping all leaf/border loopbacks
    src_nodes = ["spine-01", "spine-02"]
    dst_loopbacks = {n: info_["loopback"] for n, info_ in NODES.items()
                     if n.startswith(("leaf", "border"))}

    for src in src_nodes:
        if not is_container_running(src):
            warn(f"  Skipping {src} — container not running")
            continue
        for dst_name, dst_ip in dst_loopbacks.items():
            ntype = NODES[src]["type"]
            if ntype == "eos":
                rc, out = eos_exec(src, f"ping {dst_ip} repeat 2 timeout 2",
                                   verbose=args.verbose)
                success = rc == 0 and ("2 received" in out or "0% packet loss" in out)
            else:
                rc, out = docker_exec(src, f"ping -c 2 -W 2 {dst_ip}",
                                      verbose=args.verbose)
                success = rc == 0 and "0% packet loss" in out

            if success:
                ok(f"[{src}] → {dst_name} ({dst_ip}) reachable")
                result.passed += 1
            else:
                fail(f"[{src}] → {dst_name} ({dst_ip}) unreachable")
                result.failed += 1
                result.failures.append(f"Loopback unreachable: {src} → {dst_ip}")


# ── Section 6 — EVPN Route Table ─────────────────────────────
def check_evpn_routes(result: TestResult, args) -> None:
    header("Section 6 — EVPN Route Table (Type-2 & Type-5)")
    nodes = [args.node] if args.node else ["spine-01"]
    for node in nodes:
        if not is_container_running(node):
            continue
        ntype = NODES[node]["type"]

        if ntype == "eos":
            rc, out = eos_exec(node, "show bgp evpn route-type ip-prefix ipv4",
                               verbose=args.verbose)
            t5 = out.count("RD:")
            if t5 > 0:
                ok(f"[{node}] EVPN Type-5 IP-prefix routes: {t5} RD entries")
                result.passed += 1
            else:
                fail(f"[{node}] No EVPN Type-5 routes — VRF redistribution not working")
                result.failed += 1
                result.failures.append(f"No EVPN Type-5 routes on {node}")

            rc, out = eos_exec(node, "show bgp evpn route-type mac-ip",
                               verbose=args.verbose)
            t2 = out.count("RD:")
            if t2 > 0:
                ok(f"[{node}] EVPN Type-2 MAC/IP routes: {t2} entries")
                result.passed += 1
            else:
                info(f"[{node}] EVPN Type-2 MAC/IP: 0 entries — normal until hosts ARP")
        else:
            rc, out = frr_exec(node, "show bgp l2vpn evpn", verbose=args.verbose)
            if rc == 0 and ("Route Distinguisher" in out or "Network" in out):
                ok(f"[{node}] EVPN routes present in BGP table")
                result.passed += 1
            else:
                warn(f"[{node}] No EVPN routes visible yet")
                result.warned += 1


# ── Section 7 — ICMP Reachability ────────────────────────────
def check_ping(result: TestResult, args) -> None:
    header("Section 7 — ICMP Reachability (Server-to-Server)")
    for src, dst_ip, desc in PING_SCENARIOS:
        rc, out = docker_exec(src, f"ping -c 3 -W 2 {dst_ip}", verbose=args.verbose)
        if rc == 0 and "0% packet loss" in out:
            ok(f"{desc}  [{src} → {dst_ip}]")
            result.passed += 1
        elif rc == 0 and "packet loss" in out:
            warn(f"{desc}  [{src} → {dst_ip}]  — partial loss")
            result.warned += 1
        else:
            fail(f"{desc}  [{src} → {dst_ip}]")
            result.failed += 1
            result.failures.append(f"Ping failed: {src} → {dst_ip} ({desc})")
        if args.verbose and out:
            print(f"    {out[:200]}")


# ── Section 8 — BFD Sessions ──────────────────────────────────
def check_bfd(result: TestResult, args) -> None:
    header("Section 8 — BFD Sessions")
    nodes = [args.node] if args.node else list(NODES.keys())
    for node in nodes:
        if not is_container_running(node):
            continue
        rc, out = node_exec(node, "show bfd peers", "show bfd peers",
                            verbose=args.verbose)
        if rc != 0:
            warn(f"[{node}] BFD check failed")
            result.warned += 1
            continue
        ntype = NODES[node]["type"]
        if ntype == "eos":
            up = out.count("Up")
        else:
            up = out.lower().count("up")
        if up > 0:
            ok(f"[{node}] BFD — {up} session(s) Up")
            result.passed += 1
        else:
            warn(f"[{node}] No BFD sessions Up yet")
            result.warned += 1


# ── Section 9 — VRF Routing Tables ───────────────────────────
def check_vrf_routes(result: TestResult, args) -> None:
    header("Section 9 — VRF Routing Tables")
    vrf_map = {
        "leaf-01": ("VRF-PEDAGOGY", "192.168.10"),
        "leaf-02": ("VRF-RESEARCH", "192.168.30"),
        "leaf-03": ("VRF-SERVICES", "192.168.50"),
        "leaf-04": ("VRF-AI",       "192.168.80"),
    }
    nodes = (
        {args.node: vrf_map[args.node]}
        if args.node and args.node in vrf_map
        else vrf_map
    )
    all_prefixes = ["192.168.10", "192.168.20", "192.168.30",
                    "192.168.40", "192.168.50", "192.168.60", "192.168.80"]
    for node, (vrf, local_net) in nodes.items():
        if not is_container_running(node):
            continue
        ntype = NODES[node]["type"]
        if ntype == "eos":
            rc, out = eos_exec(node, f"show ip route vrf {vrf}",
                               verbose=args.verbose)
        else:
            rc, out = frr_exec(node, f"show ip route vrf {vrf}",
                               verbose=args.verbose)
        if rc != 0:
            fail(f"[{node}] VRF route table command failed")
            result.failed += 1
            result.failures.append(f"VRF route table on {node}")
            continue
        if local_net in out:
            ok(f"[{node}] {vrf} contains local subnet {local_net}.0/24")
            result.passed += 1
        else:
            warn(f"[{node}] {vrf} missing local subnet {local_net}.0/24")
            result.warned += 1
        imported = [p for p in all_prefixes if p in out]
        info(f"  [{node}] Prefixes in {vrf}: {len(imported)}/{len(all_prefixes)} "
             f"→ {imported}")


# ── Section 10 — Hybrid Health Summary ───────────────────────
def check_hybrid_health(result: TestResult, args) -> None:
    header("Section 10 — Hybrid Health (Arista + FRR Interop)")
    # Verify the FRR borders can reach the Arista spine loopbacks
    for border in ["border-01", "border-02"]:
        if not is_container_running(border):
            warn(f"  Skipping {border} — container not running")
            continue
        for spine, spine_lo in [("spine-01", "10.1.0.1"), ("spine-02", "10.1.0.2")]:
            rc, out = docker_exec(border, f"ping -c 2 -W 2 {spine_lo}",
                                  verbose=args.verbose)
            if rc == 0 and "0% packet loss" in out:
                ok(f"[{border}] FRR → Arista {spine} loopback ({spine_lo})")
                result.passed += 1
            else:
                fail(f"[{border}] Cannot reach {spine} loopback ({spine_lo})")
                result.failed += 1
                result.failures.append(f"FRR→Arista loopback: {border} → {spine_lo}")

    # Verify the Arista spines can reach FRR border loopbacks
    for spine in ["spine-01", "spine-02"]:
        if not is_container_running(spine):
            continue
        for border, border_lo in [("border-01", "10.1.0.21"),
                                  ("border-02", "10.1.0.22")]:
            rc, out = eos_exec(spine, f"ping {border_lo} repeat 2 timeout 2",
                               verbose=args.verbose)
            if rc == 0 and ("2 received" in out or "0% packet loss" in out):
                ok(f"[{spine}] Arista → FRR {border} loopback ({border_lo})")
                result.passed += 1
            else:
                fail(f"[{spine}] Cannot reach {border} loopback ({border_lo})")
                result.failed += 1
                result.failures.append(f"Arista→FRR loopback: {spine} → {border_lo}")


# ── Main ──────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="ESI Datacenter Lightweight (Arista + FRR) Validation Script"
    )
    parser.add_argument(
        "--section",
        choices=["containers", "bgp", "evpn", "vxlan", "loopback",
                 "routes", "ping", "bfd", "vrf", "hybrid"],
        help="Run only a specific validation section",
    )
    parser.add_argument(
        "--node",
        choices=list(NODES.keys()),
        help="Target a single node",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Print raw command output",
    )
    parser.add_argument(
        "--wait",
        type=int, default=0,
        metavar="SECONDS",
        help="Wait N seconds before running (allow BGP to converge)",
    )
    args = parser.parse_args()

    if args.wait > 0:
        info(f"Waiting {args.wait}s for BGP/EVPN convergence ...")
        time.sleep(args.wait)

    print(f"\n{BOLD}{'═' * 60}{NC}")
    print(f"{BOLD}   ESI Datacenter — Lightweight (Arista + FRR) Validation{NC}")
    print(f"{BOLD}{'═' * 60}{NC}")
    info("Arista cEOS : spine-01, spine-02, leaf-01..04")
    info("FRR         : border-01, border-02")

    result = TestResult()

    section_map = {
        "containers": check_containers,
        "bgp":        check_bgp_underlay,
        "evpn":       check_bgp_evpn,
        "vxlan":      check_vxlan_vni,
        "loopback":   check_loopback_reachability,
        "routes":     check_evpn_routes,
        "ping":       check_ping,
        "bfd":        check_bfd,
        "vrf":        check_vrf_routes,
        "hybrid":     check_hybrid_health,
    }

    if args.section:
        section_map[args.section](result, args)
    else:
        for fn in section_map.values():
            fn(result, args)

    # ── Summary ───────────────────────────────────────────────
    total = result.passed + result.failed + result.warned
    print(f"\n{BOLD}{'═' * 60}{NC}")
    print(
        f"{BOLD}   Results: "
        f"{GREEN}{result.passed} passed{NC}  "
        f"{RED}{result.failed} failed{NC}  "
        f"{YELLOW}{result.warned} warnings{NC}  "
        f"/ {total} checks{NC}"
    )
    if result.failures:
        print(f"\n{RED}{BOLD}Failed checks:{NC}")
        for f in result.failures:
            print(f"  {RED}✗{NC} {f}")
    print(f"{BOLD}{'═' * 60}{NC}\n")
    sys.exit(0 if result.failed == 0 else 1)


if __name__ == "__main__":
    main()
