#!/bin/sh
# Wrapper for shared Ring 1 firewall startup logic.

set -e

FW_NAME="firewall-01"
FW_RING1_IP="192.168.1.1"
FW_TRANSIT_GW="192.168.1.252"
FW_OUTSIDE_IP="203.0.113.10"
FW_CAMPUS_IP="10.200.0.3"

. /opt/firewall-common/startup-common.sh
