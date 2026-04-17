# Manual Log Verification Guide

This guide explains how to manually access and inspect syslog messages in the
ESI datacenter ContainerLab, particularly for Ring 6 (centralized logging).

## Quick Start

### View All Logs on Syslog Server

```bash
# Access the syslog-server container shell
docker exec -it clab-esi-datacenter-syslog-server sh

# View all collected logs
cat /var/log/messages

# Or use tail for the last N lines
tail -50 /var/log/messages
```

### View Logs in Real-Time

```bash
# Open a shell and monitor incoming logs as they arrive
docker exec -it clab-esi-datacenter-syslog-server tail -f /var/log/messages
```

---

## Detailed Instructions

### 1. Accessing the Syslog Server

The syslog-server container listens on **192.168.50.70:514 (TCP)** and stores
all received logs in `/var/log/messages`.

```bash
# Start an interactive shell in the syslog-server
docker exec -it clab-esi-datacenter-syslog-server sh

# You are now inside the container
# Verify rsyslogd is running
ps -ef | grep rsyslogd

# Verify it's listening on TCP/514
netstat -tlnp | grep 514
# or
ss -tlnp | grep 514
```

### 2. Viewing Logs

**View all logs:**

```bash
cat /var/log/messages
```

**View recent logs (last 50 lines):**

```bash
tail -50 /var/log/messages
```

**View logs from a specific time period:**

```bash
# Example: show logs from the last 10 minutes
tail -100 /var/log/messages | grep "Apr 16"
```

**Search for specific messages:**

```bash
# Search for a hostname
grep "leaf-01" /var/log/messages

# Search for a specific process
grep "kernel" /var/log/messages

# Search for error messages
grep "ERROR\|error\|CRITICAL" /var/log/messages
```

**Watch logs in real-time:**

```bash
# Monitor incoming logs as they arrive (Ctrl+C to exit)
tail -f /var/log/messages
```

### 3. Injecting Test Logs

To verify that logging is working, inject a test log from a node that can reach
the syslog server.

**From the syslog-server container:**

```bash
# Inside syslog-server shell
logger "TEST_MESSAGE_FROM_SYSLOG_SERVER"

# Check if it appears
grep "TEST_MESSAGE_FROM_SYSLOG_SERVER" /var/log/messages
```

**From a fabric node (leaf or spine):**

```bash
# From your host machine
docker exec -it clab-esi-datacenter-server-admin-01 sh

# Inside the node's shell
logger "RING6_TEST_FROM_ADMIN01"
```

**Then check if it arrived at the syslog server:**

```bash
docker exec clab-esi-datacenter-syslog-server grep "RING6_TEST_FROM_ADMIN01" /var/log/messages
```

### 4. Understanding Log Format

Syslog messages follow this format:

```
Apr 16 21:04:36 hostname process[pid]: MESSAGE TEXT
```

**Example log entry:**

```
Apr 16 21:04:36 clab-esi-datacenter-server-admin-01 kernel: RING6_VERIFICATION_TEST
```

Breaking it down:

- **Apr 16 21:04:36** — Timestamp (Month Day HH:MM:SS)
- **clab-esi-datacenter-server-admin-01** — Hostname of the node that sent the
  log
- **kernel** — Process/facility that generated the log
- **RING6_VERIFICATION_TEST** — The actual log message

### 5. Checking Specific Node Logs

To see logs from a particular node, filter by hostname:

```bash
# Logs from leaf-01
docker exec clab-esi-datacenter-syslog-server grep "leaf-01" /var/log/messages

# Logs from server-hpc-01
docker exec clab-esi-datacenter-syslog-server grep "server-hpc-01" /var/log/messages

# Logs from spine-02
docker exec clab-esi-datacenter-syslog-server grep "spine-02" /var/log/messages
```

### 6. Checking Logs on Individual Nodes

Each node also maintains its own local syslog in addition to forwarding to the
central server.

```bash
# Check logs on leaf-01
docker exec clab-esi-datacenter-leaf-01 sh -c "tail -20 /var/log/messages"

# Check logs on server-student-01
docker exec clab-esi-datacenter-server-student-01 sh -c "tail -20 /var/log/messages"

# Check logs on a spine
docker exec clab-esi-datacenter-spine-01 sh -c "tail -20 /var/log/messages"
```

### 7. Verifying Rsyslog Configuration

To ensure a node is correctly configured to forward logs:

```bash
# Check rsyslog is running on a node
docker exec clab-esi-datacenter-leaf-01 ps -ef | grep rsyslogd

# View rsyslog configuration (should include forwarding rule)
docker exec clab-esi-datacenter-leaf-01 cat /etc/rsyslog.conf | grep "192.168.50.70"
```

### 8. Troubleshooting: No Logs Appearing?

**Check if rsyslogd is running:**

```bash
docker exec clab-esi-datacenter-syslog-server ps -ef | grep rsyslogd
```

**Check if rsyslogd is listening on TCP/514:**

```bash
docker exec clab-esi-datacenter-syslog-server ss -tlnp | grep 514
```

**Check if the syslog-server can be reached from a node:**

```bash
# From a node like server-admin-01 (which should have admin subnet access)
docker exec clab-esi-datacenter-server-admin-01 sh -c "ping -c 2 192.168.50.70"

# If this fails, the node cannot reach the syslog server
# Not all nodes have routes to 192.168.50.70 (admin subnet is isolated)
```

**Check rsyslog errors on a node:**

```bash
# View rsyslog status
docker exec clab-esi-datacenter-leaf-01 sh -c "tail -50 /var/log/messages | grep rsyslog"
```

---

## Quick Command Reference

| Task                     | Command                                                                          |
| ------------------------ | -------------------------------------------------------------------------------- |
| View all syslog messages | `docker exec clab-esi-datacenter-syslog-server cat /var/log/messages`            |
| View last 50 lines       | `docker exec clab-esi-datacenter-syslog-server tail -50 /var/log/messages`       |
| Watch logs in real-time  | `docker exec -it clab-esi-datacenter-syslog-server tail -f /var/log/messages`    |
| Search for a node's logs | `docker exec clab-esi-datacenter-syslog-server grep "leaf-01" /var/log/messages` |
| Inject a test log        | `docker exec clab-esi-datacenter-server-admin-01 logger "TEST_MESSAGE"`          |
| Verify syslog is running | `docker exec clab-esi-datacenter-syslog-server ps -ef \| grep rsyslogd`          |
| Check TCP/514 listening  | `docker exec clab-esi-datacenter-syslog-server ss -tlnp \| grep 514`             |

---

## Important Notes

### Reachability Limitation

Not all nodes can send logs to the syslog server due to VRF (Virtual Routing and
Forwarding) isolation:

- ✅ **Can reach 192.168.50.70**: server-admin-01, server-admin-02, leaf-03,
  leaf-04, syslog-server itself
- ❌ **Cannot reach 192.168.50.70**: leaf-01 through leaf-02, leaf-05 through
  leaf-10, spine nodes, other service nodes

This is **intentional architectural isolation** (Admin VRF separation) and not a
bug. Nodes in the admin VRF or directly connected to the admin subnet can
successfully forward logs.

### Log Retention

Logs are stored in `/var/log/messages` on the syslog-server container. When the
container is stopped/restarted, logs are retained because:

- The containerlab volume binds are configured to preserve state
- OR logs exist in the running container's filesystem (lost on destroy)

To preserve logs across deployments, mount a persistent volume in the
syslog-server definition.

---

## Example Workflow

Here's a typical workflow to test and verify logging:

```bash
# 1. Inject a test log from a reachable node
docker exec clab-esi-datacenter-server-admin-01 sh -c "logger 'MANUAL_TEST_$(date +%s)'"

# 2. Wait 1-2 seconds for delivery
sleep 2

# 3. Check if it arrived on the syslog server
docker exec clab-esi-datacenter-syslog-server tail -5 /var/log/messages

# 4. If you see your test message, Ring 6 is working!
```

---

## Running the Automated Verification Script

For a fully automated test, use the Ring 6 verification script:

```bash
cd /path/to/frr-containerlab
bash tests/T3_ring6_verify.sh
```

This script:

1. Injects a test log from server-admin-01
2. Polls the syslog server for the message
3. Reports success or failure
4. Returns exit code 0 on success, 1 on failure
