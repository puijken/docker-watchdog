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

echo "[Watchdog] Starting for container '$CONTAINER'"
echo "[Watchdog] Check interval: ${CHECK_INTERVAL}s | Idle limit: ${IDLE_LIMIT}s"
echo "[Watchdog] Using CHECK_CMD: $CHECK_CMD"

# Graceful exit handler — stops the target container if watchdog is terminated
trap 'echo "[Watchdog] Caught stop signal — stopping $CONTAINER"; docker stop "$CONTAINER" >/dev/null 2>&1 || true; exit 0' INT TERM

# === Main persistent loop ===
while true; do
  # Wait for the target container to exist
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "[Watchdog] [$CONTAINER] Container does not exist — sleeping 60s."
    sleep 60
    continue
  fi

  # Wait for the container to start running
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "[Watchdog] [$CONTAINER] Not running — waiting for start..."
    sleep 10
    continue
  fi

  echo "[Watchdog] [$CONTAINER] Running — starting activity monitoring loop."
  LAST_ACTIVE=$(date +%s)

  # === Inner monitoring loop ===
  while docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; do
    if docker exec "$CONTAINER" sh -c "$CHECK_CMD" | grep -q .; then
      LAST_ACTIVE=$(date +%s)
      echo "[Watchdog] [$CONTAINER] Activity detected — idle timer reset."
    else
      NOW=$(date +%s)
      IDLE_TIME=$((NOW - LAST_ACTIVE))
      echo "[Watchdog] [$CONTAINER] Idle for ${IDLE_TIME}s."
      if [ "$IDLE_TIME" -ge "$IDLE_LIMIT" ]; then
        echo "[Watchdog] [$CONTAINER] Idle > ${IDLE_LIMIT}s — stopping container."
        docker stop "$CONTAINER"
        echo "[Watchdog] [$CONTAINER] Container stopped — returning to wait state."
        break
      fi
    fi

    sleep "$CHECK_INTERVAL"
  done

  echo "[Watchdog] [$CONTAINER] Monitoring loop ended — rechecking in 10s."
  sleep 10
done
