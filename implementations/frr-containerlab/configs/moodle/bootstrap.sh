#!/bin/sh
set -eu

MOODLE_DIR="${MOODLE_DIR:-/opt/bitnami/moodle}"
SEED_SCRIPT="${SEED_SCRIPT:-/opt/esi-moodle/seed-esi-course.php}"
PHP_BIN="${PHP_BIN:-}"

if [ -z "$PHP_BIN" ]; then
  if command -v php >/dev/null 2>&1; then
    PHP_BIN="$(command -v php)"
  elif [ -x /opt/bitnami/php/bin/php ]; then
    PHP_BIN="/opt/bitnami/php/bin/php"
  else
    echo "[moodle-bootstrap] php binary not found" >&2
    exit 1
  fi
fi

echo "[moodle-bootstrap] waiting for Moodle web service at ${MOODLE_DIR}"
for attempt in $(seq 1 180); do
  if [ -f "${MOODLE_DIR}/config.php" ] && pgrep -f "httpd.*FOREGROUND" >/dev/null 2>&1; then
    if "$PHP_BIN" "$SEED_SCRIPT"; then
      chown -R daemon:daemon /bitnami/moodledata 2>/dev/null || true
      echo "[moodle-bootstrap] demo course and identities are ready"
      exit 0
    fi
  fi
  echo "[moodle-bootstrap] not ready yet (attempt ${attempt}/180)"
  sleep 5
done

echo "[moodle-bootstrap] Moodle did not become ready in time" >&2
exit 1
