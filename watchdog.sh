#!/bin/sh
set -eu

# === Configurable environment variables ===
CONTAINER="${TARGET_CONTAINER:?TARGET_CONTAINER must be set}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"  # seconds between activity checks
IDLE_LIMIT="${IDLE_LIMIT:-900}"         # seconds of inactivity before stopping
LOG_LEVEL="${LOG_LEVEL:-normal}"        # quiet | normal | debug

# Require CHECK_CMD explicitly — no default fallback
if [ -z "${CHECK_CMD:-}" ]; then
  echo "[Watchdog] ERROR: CHECK_CMD environment variable must be set (defines how to detect activity inside '$CONTAINER')."
  echo "[Watchdog] Example: CHECK_CMD=ss -tn state established | grep :3000 | grep -q ."
  exit 1
fi

# === Logging helpers ===
log() {
  [ "$LOG_LEVEL" != "quiet" ] && echo "[Watchdog] $*"
}

log_debug() {
  [ "$LOG_LEVEL" = "debug" ] && echo "[Watchdog][DEBUG] $*"
}

log "Starting for container '$CONTAINER'"
log "Check interval: ${CHECK_INTERVAL}s | Idle limit: ${IDLE_LIMIT}s | Log level: ${LOG_LEVEL}"
log "Using CHECK_CMD: $CHECK_CMD"

# Graceful exit handler — stop the target container if watchdog is terminated
trap 'log "Caught stop signal — stopping $CONTAINER"; docker stop "$CONTAINER" >/dev/null 2>&1 || true; exit 0' INT TERM

LAST_STATE="none"
LAST_ACTIVE=0

# === Main persistent loop ===
while true; do

  # Check if container exists
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    if [ "$LAST_STATE" != "missing" ]; then
      log "[$CONTAINER] Container not found — waiting for creation..."
      LAST_STATE="missing"
    fi
    sleep 30
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

  # Container is running
  if [ "$LAST_STATE" != "running" ]; then
    log "[$CONTAINER] Running — starting activity monitoring loop."
    LAST_STATE="running"
    # Do not reset LAST_ACTIVE here — only on actual activity
  fi

  # === Inner monitoring loop ===
  while docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; do
    if docker exec "$CONTAINER" sh -c "$CHECK_CMD"; then
      # Activity detected — reset idle timer
      LAST_ACTIVE=$(date +%s)
      log_debug "[$CONTAINER] Activity detected — idle timer reset."
    else
      NOW=$(date +%s)
      if [ "$LAST_ACTIVE" -eq 0 ]; then
        # First time no activity — start counting immediately
        LAST_ACTIVE=$((NOW - CHECK_INTERVAL))
      fi
      IDLE_TIME=$((NOW - LAST_ACTIVE))
      log_debug "[$CONTAINER] Idle for ${IDLE_TIME}s."
      if [ "$IDLE_TIME" -ge "$IDLE_LIMIT" ]; then
        log "[$CONTAINER] Idle > ${IDLE_LIMIT}s — stopping container."
        docker stop "$CONTAINER"
        LAST_STATE="stopped"
        break
      fi
    fi

    sleep "$CHECK_INTERVAL"
  done

  log_debug "[$CONTAINER] Monitoring loop ended — rechecking in 10s."
  sleep 10
done