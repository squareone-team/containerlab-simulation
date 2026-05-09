#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="${LAB_NAME:-esi-datacenter}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:-esi-jupyter-demo-token}"
JUPYTER_HOST="${JUPYTER_HOST:-hpc-jupyter.esi.internal}"
JUPYTER_DNS_SERVER="${JUPYTER_DNS_SERVER:-192.168.50.30}"
KEEP_TEST_NOTEBOOKS="${KEEP_TEST_NOTEBOOKS:-1}"
CLAB_PREFIX="clab-${LAB_NAME}"

JUPYTER_NODE="${CLAB_PREFIX}-server-hpc-jupyter"
ADMIN_NODE="${CLAB_PREFIX}-server-admin-01"
STUDENT_NODE="${CLAB_PREFIX}-server-student-01"
JUPYTER_URL="https://${JUPYTER_HOST}:8080/hub/login"

PASS=0
FAIL=0

ok() {
  echo "[PASS] $1"
  PASS=$((PASS + 1))
}

ko() {
  echo "[FAIL] $1"
  FAIL=$((FAIL + 1))
}

require_container() {
  local node="$1"
  if docker ps --format '{{.Names}}' | grep -qx "$node"; then
    ok "container $node is running"
  else
    ko "container $node is not running"
  fi
}

fetch_jupyter_login() {
  local node="$1"
  local output=""
  local attempt=1

  while [ "$attempt" -le 5 ]; do
    if output="$(
      docker exec "$node" sh -lc "
        set -eu
        if command -v curl >/dev/null 2>&1; then
          curl -kfsS --max-time 8 '${JUPYTER_URL}'
        elif command -v wget >/dev/null 2>&1; then
          wget -qO- --timeout=8 --no-check-certificate '${JUPYTER_URL}'
        else
          echo 'missing curl/wget' >&2
          exit 127
        fi
      " 2>&1
    )"; then
      if [[ "$output" == *"<html"* || "$output" == *"JupyterHub"* || "$output" == *"jupyterhub"* ]]; then
        return 0
      fi
    fi

    attempt=$((attempt + 1))
    sleep 2
  done

  printf '%s\n' "$output" | sed -n '1,12p' >&2
  return 1
}

echo "=== Jupyter Access and Execution Verification ==="

require_container "$JUPYTER_NODE"
require_container "$ADMIN_NODE"
require_container "$STUDENT_NODE"

if docker exec "$JUPYTER_NODE" sh -lc "ss -lntp | grep -q ':8080'"; then
  ok "Jupyter is listening on TCP/8080"
else
  ko "Jupyter is not listening on TCP/8080"
fi

if docker exec "$ADMIN_NODE" sh -lc "getent hosts '${JUPYTER_HOST}' >/dev/null 2>&1"; then
  ok "Admin node resolves ${JUPYTER_HOST} via default resolver"
else
  ko "Admin node cannot resolve ${JUPYTER_HOST} via default resolver"
fi

if docker exec "$STUDENT_NODE" sh -lc "getent hosts '${JUPYTER_HOST}' >/dev/null 2>&1"; then
  ok "Student node resolves ${JUPYTER_HOST} via default resolver"
else
  ko "Student node cannot resolve ${JUPYTER_HOST} via default resolver"
fi

if fetch_jupyter_login "$ADMIN_NODE"; then
  ok "Admin node can load JupyterHub over HTTPS via DNS name"
else
  ko "Admin node cannot load JupyterHub over HTTPS via DNS name"
fi

if fetch_jupyter_login "$STUDENT_NODE"; then
  ok "Student node can load JupyterHub over HTTPS via DNS name"
else
  ko "Student node cannot load JupyterHub over HTTPS via DNS name"
fi

TMP_NOTEBOOK="$(mktemp /tmp/jupyter-proof.XXXXXX.ipynb)"
trap 'rm -f "$TMP_NOTEBOOK"' EXIT

REMOTE_NOTEBOOK="/tmp/proof.ipynb"
REMOTE_EXECUTED_NOTEBOOK="/tmp/proof.executed.ipynb"

cat > "$TMP_NOTEBOOK" <<'EOF'
{
  "cells": [
    {
      "cell_type": "code",
      "execution_count": null,
      "metadata": {},
      "outputs": [],
      "source": [
        "x = 6 * 7\n",
        "print('result', x)\n"
      ]
    }
  ],
  "metadata": {
    "kernelspec": {
      "display_name": "Python 3",
      "language": "python",
      "name": "python3"
    },
    "language_info": {
      "name": "python"
    }
  },
  "nbformat": 4,
  "nbformat_minor": 5
}
EOF

if docker cp "$TMP_NOTEBOOK" "$JUPYTER_NODE:${REMOTE_NOTEBOOK}" && \
   docker exec "$JUPYTER_NODE" sh -lc "jupyter nbconvert --to notebook --execute ${REMOTE_NOTEBOOK} --output ${REMOTE_EXECUTED_NOTEBOOK} --ExecutePreprocessor.timeout=120 >/tmp/jupyter-nbconvert.log 2>&1" && \
   docker exec "$JUPYTER_NODE" sh -lc "grep -q 'result 42' ${REMOTE_EXECUTED_NOTEBOOK}"; then
  ok "Notebook execution succeeded and produced 'result 42'"
else
  ko "Notebook execution failed"
fi

if [ "$KEEP_TEST_NOTEBOOKS" = "1" ]; then
  ok "Kept proof notebooks in Jupyter container (${REMOTE_NOTEBOOK}, ${REMOTE_EXECUTED_NOTEBOOK})"
else
  docker exec "$JUPYTER_NODE" sh -lc "rm -f ${REMOTE_NOTEBOOK} ${REMOTE_EXECUTED_NOTEBOOK}" >/dev/null 2>&1 || true
  ok "Removed temporary proof notebooks from Jupyter container"
fi

echo "==============================================="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
