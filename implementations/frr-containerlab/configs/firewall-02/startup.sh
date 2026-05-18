#!/bin/sh
# Wrapper for shared Ring 1 firewall startup logic.

set -e

FW_NAME="firewall-02"
FW_RING1_IP="192.168.1.2"
FW_TRANSIT_GW="192.168.1.253"
FW_OUTSIDE_IP="203.0.113.11"
FW_CAMPUS_IP="10.200.0.4"

. /opt/firewall-common/startup-common.sh
