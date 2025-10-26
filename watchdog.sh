#!/bin/sh
set -eu

# === Configurable environment variables ===
CONTAINER="${TARGET_CONTAINER:?TARGET_CONTAINER must be set}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"  # seconds between checks
IDLE_LIMIT="${IDLE_LIMIT:-900}"         # seconds of inactivity before stopping
LOG_LEVEL="${LOG_LEVEL:-normal}"        # quiet | normal | debug

# Require CHECK_CMD explicitly
if [ -z "${CHECK_CMD:-}" ]; then
  echo "[Watchdog] ERROR: CHECK_CMD environment variable must be set (defines how to detect activity inside '$CONTAINER')."
  echo "[Watchdog] Example:"
  echo "  CHECK_CMD='ss -tn state established | grep :3000 | grep -q .'"
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

# Graceful exit — stop container if watchdog is terminated
trap 'log "Caught stop signal — stopping $CONTAINER"; docker stop "$CONTAINER" >/dev/null 2>&1 || true; exit 0' INT TERM

LAST_STATE="none"
LAST_ACTIVE=0

# === Main loop ===
while true; do
  # Check container existence
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    [ "$LAST_STATE" != "missing" ] && log "[$CONTAINER] Container not found — waiting..." && LAST_STATE="missing"
    sleep 10
    continue
  fi

  # Check if container is running
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    [ "$LAST_STATE" != "stopped" ] && log "[$CONTAINER] Not running — waiting..." && LAST_STATE="stopped"
    sleep 10
    continue
  fi

  # Container is running
  [ "$LAST_STATE" != "running" ] && log "[$CONTAINER] Running — starting activity monitoring loop." && LAST_STATE="running"

  # If first run, set LAST_ACTIVE to now
  [ "$LAST_ACTIVE" -eq 0 ] && LAST_ACTIVE=$(date +%s)

  # === Inner monitoring loop ===
  while docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; do
    # Run CHECK_CMD inside container
    if docker exec "$CONTAINER" sh -c "$CHECK_CMD"; then
      # Activity detected → reset timer
      LAST_ACTIVE=$(date +%s)
      log_debug "[$CONTAINER] Activity detected — idle timer reset."
    else
      NOW=$(date +%s)
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