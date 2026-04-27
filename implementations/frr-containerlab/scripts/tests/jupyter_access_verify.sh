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
JUPYTER_URL="http://${JUPYTER_HOST}:8080/tree?token=${JUPYTER_TOKEN}"

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

if docker exec "$ADMIN_NODE" sh -lc "wget -qO- --timeout=8 '${JUPYTER_URL}' | grep -qi '<html'"; then
  ok "Admin node can load Jupyter over HTTP via DNS name"
else
  ko "Admin node cannot load Jupyter over HTTP via DNS name"
fi

if docker exec "$STUDENT_NODE" sh -lc "wget -qO- --timeout=8 '${JUPYTER_URL}' | grep -qi '<html'"; then
  ok "Student node can load Jupyter over HTTP via DNS name"
else
  ko "Student node cannot load Jupyter over HTTP via DNS name"
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
