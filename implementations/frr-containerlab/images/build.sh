#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker build -t esi/alpine-host:3.20 "$ROOT_DIR/alpine-host"
docker build -t esi/alpine-services:3.20 "$ROOT_DIR/alpine-services"
docker build -t esi/alpine-zabbix:3.20 "$ROOT_DIR/alpine-zabbix"
docker build -t esi/alpine-firewall:3.20 "$ROOT_DIR/alpine-firewall"
docker build -t esi/alpine-exporter:3.20 "$ROOT_DIR/alpine-exporter"
docker build -t esi/frr-node:latest "$ROOT_DIR/frr-node"
