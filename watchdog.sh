#!/bin/sh
set -eu

# === Configurable environment variables ===
CONTAINER="${TARGET_CONTAINER:?TARGET_CONTAINER must be set}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
IDLE_LIMIT="${IDLE_LIMIT:-900}"
LOG_LEVEL="${LOG_LEVEL:-normal}"   # Options: normal | quiet | debug

# Require CHECK_CMD explicitly — no default fallback
if [ -z "${CHECK_CMD:-}" ]; then
  echo "[Watchdog] ERROR: CHECK_CMD environment variable must be set (defines how to detect activity inside '$CONTAINER')."
  echo "[Watchdog] Example:"
  echo "  CHECK_CMD="ss -tn state established | grep ':3000' | grep -q ."
  exit 1
fi

# === Logging helper functions ===
log() {
  [ "$LOG_LEVEL" != "quiet" ] && echo "[Watchdog] $*"
}

log_debug() {
  [ "$LOG_LEVEL" = "debug" ] && echo "[Watchdog][DEBUG] $*"
}

log "Starting for container '$CONTAINER'"
log "Check interval: ${CHECK_INTERVAL}s | Idle limit: ${IDLE_LIMIT}s | Log level: ${LOG_LEVEL}"
log "Using CHECK_CMD: $CHECK_CMD"

# Graceful exit handler — stops the target container if watchdog is terminated
trap 'log "Caught stop signal — stopping $CONTAINER"; docker stop "$CONTAINER" >/dev/null 2>&1 || true; exit 0' INT TERM

LAST_STATE="none"

# === Main persistent loop ===
while true; do
  # Check if container exists
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    if [ "$LAST_STATE" != "missing" ]; then
      log "[$CONTAINER] Container not found — waiting for creation..."
      LAST_STATE="missing"
    fi
    sleep 60
    continue
  fi

  # Check if container is running
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    if [ "$LAST_STATE" != "stopped" ]; then
      log "[$CONTAINER] Not running — waiting for start..."
      LAST_STATE="stopped"
    fi
    sleep 10
    continue
  fi

  if [ "$LAST_STATE" != "running" ]; then
    log "[$CONTAINER] Running — starting activity monitoring loop."
    LAST_STATE="running"
  fi

  LAST_ACTIVE=$(date +%s)

  # === Inner monitoring loop ===
  while docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; do
    if docker exec "$CONTAINER" sh -c "$CHECK_CMD"; then
      LAST_ACTIVE=$(date +%s)
      log_debug "[$CONTAINER] Activity detected — idle timer reset."
    else
      NOW=$(date +%s)
      IDLE_TIME=$((NOW - LAST_ACTIVE))
      log_debug "[$CONTAINER] Idle for ${IDLE_TIME}s."
      if [ "$IDLE_TIME" -ge "$IDLE_LIMIT" ]; then
        log "[$CONTAINER] Idle > ${IDLE_LIMIT}s — stopping container."
        docker stop "$CONTAINER"
        log "[$CONTAINER] Container stopped — returning to wait state."
        LAST_STATE="stopped"
        break
      fi
    fi

    sleep "$CHECK_INTERVAL"
  done

  log_debug "[$CONTAINER] Monitoring loop ended — rechecking in 10s."
  sleep 10
done