# FRR ContainerLab Docs

The docs are now split by purpose instead of shortcut files. Start with the short runbooks, then open reference material only when you need tables or implementation details.

## Structure

| Area | Purpose | Best entry point |
| --- | --- | --- |
| `theory/` | Architecture, traffic model, identity model | [Topology and feature map](./theory/topology-and-feature-map.md) |
| `practical/getting-started/` | Deploy, reconfigure, baseline checks | [Lab lifecycle and baseline](./practical/getting-started/lab-lifecycle-and-baseline.md) |
| `practical/routing/` | Fabric, border, campus edge, DMZ paths | [Border routing and internet](./practical/routing/border-routing-and-internet.md) |
| `practical/security/` | Firewall, identity, NAC, VPN, IDS | [Identity and access](./practical/security/identity-and-access.md) |
| `practical/services/` | DNS, DHCP, NTP, Moodle, observability | [Moodle LMS](./practical/services/moodle-lms.md) |
| `practical/operations/` | QoS and recovery exercises | [Resilience and recovery](./practical/operations/resilience-and-recovery.md) |
| `reference/` | Stable matrices, credentials, image notes | [Credentials](./reference/credentials.md) |

## Daily Flow

1. Deploy or reconfigure from [Lab lifecycle and baseline](./practical/getting-started/lab-lifecycle-and-baseline.md).
2. Validate browser-facing access with `scripts/tests/browser_pov_validation.sh`.
3. Validate VPN with `scripts/tests/vpn_access_validation.sh`.
4. Validate Moodle from [Moodle LMS](./practical/services/moodle-lms.md).

## Current User-Facing Services

| Service | Name or URL | Notes |
| --- | --- | --- |
| NAC portal | `https://192.168.110.1:8443/` | ESI-styled captive portal, HTTP redirects to HTTPS. |
| VPN platform | `https://198.51.100.20:8448/` | ESI-branded WireGuard enrollment with lab key generation. |
| Internet demo | `http://www.google.com/` | DNS points to the simulated Internet webserver at `198.18.3.10`. |
| Moodle LMS | `http://moodle.esi.dz/` | Real Moodle container at `198.51.100.30`. |
| JupyterHub | `https://hpc-jupyter.esi.internal:8080/hub/login` | Internal service after NAC/VPN role admission. |

The default topology is headless for 8 GB machines. Launch the optional GUI viewers only when you need them:

```bash
containerlab deploy -t esi-browser-viewers.clab.yml
```

Shortcut documents and old architecture dumps were removed. New docs should land inside one of the folders above, not at the top level.
