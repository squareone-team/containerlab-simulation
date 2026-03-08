#!/usr/bin/env python3
"""
verify_arista_lab.py — ESI Datacenter Arista cEOS Validation
=============================================================
Validates the full EVPN/VXLAN fabric by running EOS show commands
and ICMP reachability tests via docker exec.

Usage:
    python3 scripts/verify_arista_lab.py
    python3 scripts/verify_arista_lab.py --section bgp
    python3 scripts/verify_arista_lab.py --section vxlan
    python3 scripts/verify_arista_lab.py --section ping
    python3 scripts/verify_arista_lab.py --node spine-01
    python3 scripts/verify_arista_lab.py --verbose
    python3 scripts/verify_arista_lab.py --wait 30
"""

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
LAB_PREFIX = "clab-esi-arista"

NODES = {
    "spine-01":  {"asn": 65000, "loopback": "10.1.0.1"},
    "spine-02":  {"asn": 65000, "loopback": "10.1.0.2"},
    "leaf-01":   {"asn": 65001, "loopback": "10.1.0.11"},
    "leaf-02":   {"asn": 65002, "loopback": "10.1.0.12"},
    "leaf-03":   {"asn": 65003, "loopback": "10.1.0.13"},
    "leaf-04":   {"asn": 65004, "loopback": "10.1.0.14"},
    "border-01": {"asn": 65005, "loopback": "10.1.0.21"},
    "border-02": {"asn": 65005, "loopback": "10.1.0.22"},
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

# ICMP reachability scenarios (src_container, dst_ip, description)
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
    full_cmd = f"Cli -c '{cmd}'"
    docker_cmd = ["docker", "exec", container_name(node), "bash", "-c", full_cmd]
    if verbose:
        info(f"  [{node}] {cmd}")
    try:
        result = subprocess.run(docker_cmd, capture_output=True, text=True, timeout=15)
        return result.returncode, result.stdout.strip()
    except subprocess.TimeoutExpired:
        return 1, "TIMEOUT"
    except Exception as e:
        return 1, str(e)


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


def is_container_running(node: str) -> bool:
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Running}}", container_name(node)],
        capture_output=True, text=True,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


# ── Section 1 — Container Health ─────────────────────────────
def check_containers(result: TestResult, args) -> None:
    header("Section 1 — Container Health")
    nodes = [args.node] if args.node else list(NODES.keys())
    for node in nodes:
        if is_container_running(node):
            ok(f"{node} is running")
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
        rc, out = eos_exec(node, "show bgp summary", verbose=args.verbose)
        if rc != 0:
            fail(f"[{node}] BGP summary command failed")
            result.failed += 1
            result.failures.append(f"BGP underlay unreachable on {node}")
            continue
        established = out.count("Estab")
        if established > 0:
            ok(f"[{node}] Underlay BGP — {established} session(s) Established")
            result.passed += 1
        else:
            fail(f"[{node}] No Established underlay BGP sessions")
            result.failed += 1
            result.failures.append(f"No BGP underlay sessions on {node}")
        if args.verbose:
            print(out[:400])


# ── Section 3 — BGP EVPN Overlay ─────────────────────────────
def check_bgp_evpn(result: TestResult, args) -> None:
    header("Section 3 — BGP EVPN Overlay Sessions")
    nodes = [args.node] if args.node else list(NODES.keys())
    for node in nodes:
        if not is_container_running(node):
            warn(f"  Skipping {node} — container not running")
            continue
        rc, out = eos_exec(node, "show bgp evpn summary", verbose=args.verbose)
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
        established = out.count("Estab")
        if established == len(expected):
            ok(f"[{node}] All EVPN peers Established ({established}/{len(expected)})")
            result.passed += 1
        else:
            warn(f"[{node}] EVPN peers Established: {established}/{len(expected)}")
            result.warned += 1
        if args.verbose:
            print(out[:400])


# ── Section 4 — VXLAN VNI Membership ─────────────────────────
def check_vxlan_vni(result: TestResult, args) -> None:
    header("Section 4 — VXLAN VNI Membership")
    eligible = {k for k in NODES if k.startswith(("leaf", "border"))}
    nodes = [args.node] if (args.node and args.node in eligible) else list(eligible)
    for node in nodes:
        if not is_container_running(node):
            warn(f"  Skipping {node} — container not running")
            continue
        rc, out = eos_exec(node, "show vxlan vni", verbose=args.verbose)
        if rc != 0:
            fail(f"[{node}] 'show vxlan vni' failed")
            result.failed += 1
            result.failures.append(f"VXLAN VNI check failed on {node}")
            continue
        expected = VNI_MEMBERSHIP.get(node, [])
        missing = [v for v in expected if str(v) not in out]
        if not missing:
            ok(f"[{node}] All VNIs present: {expected}")
            result.passed += 1
        else:
            fail(f"[{node}] Missing VNIs: {missing}")
            result.failed += 1
            result.failures.append(f"Missing VNIs on {node}: {missing}")
        if args.verbose:
            print(out)


# ── Section 5 — EVPN-discovered Remote VTEPs ─────────────────
def check_vtep_table(result: TestResult, args) -> None:
    header("Section 5 — EVPN-Discovered Remote VTEPs")
    # Note: with pure BGP-EVPN, the static flood table is always empty.
    # 'show vxlan vtep' shows unicast VTEPs learned via Type-2/3 EVPN routes.
    # Borders are L3-only VTEPs and appear only after MAC/IP routes resolve,
    # so we only require the other leaf peers (minimum 2).
    leaf_nodes = [k for k in NODES if k.startswith("leaf")]
    nodes = [args.node] if (args.node and args.node in leaf_nodes) else leaf_nodes
    for node in nodes:
        if not is_container_running(node):
            continue
        rc, out = eos_exec(node, "show vxlan vtep", verbose=args.verbose)
        if rc != 0:
            warn(f"[{node}] 'show vxlan vtep' failed")
            result.warned += 1
            continue
        # Count remote unicast VTEPs discovered via EVPN
        vtep_count = out.count("unicast")
        if vtep_count >= 2:
            ok(f"[{node}] EVPN remote VTEPs: {vtep_count} unicast peers discovered")
            result.passed += 1
        elif vtep_count == 1:
            warn(f"[{node}] Only {vtep_count} remote VTEP discovered (expected ≥2, may need traffic)")
            result.warned += 1
        else:
            warn(f"[{node}] No remote VTEPs yet — EVPN Type-3 IMET routes pending")
            result.warned += 1
        if args.verbose:
            print(out)


# ── Section 6 — EVPN Route Table ─────────────────────────────
def check_evpn_routes(result: TestResult, args) -> None:
    header("Section 6 — EVPN Route Table (Type-2 & Type-5)")
    nodes = [args.node] if args.node else ["spine-01"]
    for node in nodes:
        if not is_container_running(node):
            continue
        # Type-5 (IP-prefix) — must be present once any VRF redistributes connected
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

        # Type-2 (MAC/IP) — optional until hosts generate ARP traffic
        rc, out = eos_exec(node, "show bgp evpn route-type mac-ip",
                           verbose=args.verbose)
        t2 = out.count("RD:")
        if t2 > 0:
            ok(f"[{node}] EVPN Type-2 MAC/IP routes: {t2} entries (hosts active)")
            result.passed += 1
        else:
            info(f"[{node}] EVPN Type-2 MAC/IP: 0 entries — normal until hosts generate ARP")


# ── Section 7 — ICMP Reachability ────────────────────────────
def check_ping(result: TestResult, args) -> None:
    header("Section 7 — ICMP Reachability")
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
        rc, out = eos_exec(node, "show bfd peers", verbose=args.verbose)
        if rc != 0:
            warn(f"[{node}] BFD check failed")
            result.warned += 1
            continue
        up = out.count("Up")
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
        rc, out = eos_exec(node, f"show ip route vrf {vrf}", verbose=args.verbose)
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


# ── Main ──────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="ESI Datacenter Arista cEOS Validation Script"
    )
    parser.add_argument(
        "--section",
        choices=["containers", "bgp", "evpn", "vxlan", "vtep",
                 "routes", "ping", "bfd", "vrf"],
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

    print(f"\n{BOLD}{'═' * 54}{NC}")
    print(f"{BOLD}   ESI Datacenter — Arista cEOS Validation Suite{NC}")
    print(f"{BOLD}{'═' * 54}{NC}")

    result = TestResult()

    section_map = {
        "containers": check_containers,
        "bgp":        check_bgp_underlay,
        "evpn":       check_bgp_evpn,
        "vxlan":      check_vxlan_vni,
        "vtep":       check_vtep_table,
        "routes":     check_evpn_routes,
        "ping":       check_ping,
        "bfd":        check_bfd,
        "vrf":        check_vrf_routes,
    }

    if args.section:
        section_map[args.section](result, args)
    else:
        for fn in section_map.values():
            fn(result, args)

    # ── Summary ───────────────────────────────────────────────
    total = result.passed + result.failed + result.warned
    print(f"\n{BOLD}{'═' * 54}{NC}")
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
    print(f"{BOLD}{'═' * 54}{NC}\n")
    sys.exit(0 if result.failed == 0 else 1)


if __name__ == "__main__":
    main()
