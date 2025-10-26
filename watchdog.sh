#!/bin/sh
set -eu

# === Configurable environment variables ===
CONTAINER="${TARGET_CONTAINER:?TARGET_CONTAINER must be set}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
IDLE_LIMIT="${IDLE_LIMIT:-900}"

# Require CHECK_CMD explicitly — no default fallback
if [ -z "${CHECK_CMD:-}" ]; then
  echo "[Watchdog] ERROR: CHECK_CMD environment variable must be set (defines how to detect activity inside '$CONTAINER')."
  echo "[Watchdog] Example: CHECK_CMD=\"ss -tn state established '( sport = :3001 )'\""
  exit 1
fi

LAST_ACTIVE=$(date +%s)

echo "[Watchdog] Monitoring container '$CONTAINER' (interval: ${CHECK_INTERVAL}s, idle limit: ${IDLE_LIMIT}s)"
echo "[Watchdog] Using check command: $CHECK_CMD"

# === Graceful shutdown handler ===
cleanup() {
  echo "[Watchdog] Received termination signal. Stopping '$CONTAINER' to avoid orphaned containers..."
  docker stop "$CONTAINER" >/dev/null 2>&1 || true
  echo "[Watchdog] Cleanup complete. Exiting."
  exit 0
}

trap cleanup INT TERM

# === Main loop ===
while true; do
  if docker ps -q -f name="$CONTAINER" | grep -q .; then
    if docker exec "$CONTAINER" sh -c "$CHECK_CMD" 2>/dev/null | tail -n +2 | grep -q .; then
      LAST_ACTIVE=$(date +%s)
      echo "[Watchdog] [$CONTAINER] Activity detected — reset idle timer."
    else
      NOW=$(date +%s)
      IDLE_TIME=$((NOW - LAST_ACTIVE))
      echo "[Watchdog] [$CONTAINER] Idle for ${IDLE_TIME}s."
      if [ "$IDLE_TIME" -ge "$IDLE_LIMIT" ]; then
        echo "[Watchdog] [$CONTAINER] Idle > $IDLE_LIMIT seconds — stopping container."
        docker stop "$CONTAINER" >/dev/null 2>&1 || true
        LAST_ACTIVE=$(date +%s)
      fi
    fi
  else
    echo "[Watchdog] [$CONTAINER] Not running — waiting..."
    LAST_ACTIVE=$(date +%s)
  fi
  sleep "$CHECK_INTERVAL"
done