#!/bin/bash

################################################################################
# Container Watchdog Script
# Monitors a container for incoming connections and stops it after timeout
################################################################################

# Configuration Variables (read from environment, with defaults)
CONTAINER_TO_WATCH="${CONTAINER_TO_WATCH:-}"
PORT_TO_WATCH="${PORT_TO_WATCH:-}"
COMMAND="${COMMAND:-ss}"  # Options: "ss" or "netstat"
TIMEOUT="${TIMEOUT:-300}"   # Seconds before stopping container (5 minutes)
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"  # Seconds between checks
STARTUP_GRACE_PERIOD="${STARTUP_GRACE_PERIOD:-5}"  # Seconds to wait after container start before monitoring

################################################################################
# Functions
################################################################################

# Logging function with WATCHDOG prefix
log() {
    local message="$1"
    echo "[WATCHDOG: $(date +'%Y-%m-%d %H:%M:%S')] $message"
}

# Error handling function
error_exit() {
    local message="$1"
    log "ERROR: $message"
    exit 1
}

# Validate configuration
validate_config() {
    # Check required variables
    if [[ -z "$CONTAINER_TO_WATCH" ]]; then
        error_exit "CONTAINER_TO_WATCH environment variable is not set"
    fi

    if [[ -z "$PORT_TO_WATCH" ]]; then
        error_exit "PORT_TO_WATCH environment variable is not set"
    fi

    if [[ ! "$COMMAND" =~ ^(ss|netstat)$ ]]; then
        error_exit "COMMAND must be either 'ss' or 'netstat', got: $COMMAND"
    fi

    # Check if command exists
    if ! command -v "$COMMAND" &> /dev/null; then
        error_exit "Command '$COMMAND' not found on system"
    fi

    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        error_exit "Docker command not found"
    fi
}

# Check if container exists
container_exists() {
    docker inspect "$CONTAINER_TO_WATCH" &> /dev/null
    return $?
}

# Check if container is running
container_is_running() {
    local state=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_TO_WATCH" 2>/dev/null)
    [[ "$state" == "true" ]]
}

# Check for ESTABLISHED connections on the specified port
check_established_connections() {
    local established_count=0

    case "$COMMAND" in
        ss)
            # ss: filter for ESTAB state and specified port
            established_count=$(docker exec "$CONTAINER_TO_WATCH" ss -tn 2>/dev/null | \
                grep "ESTAB" | grep ":${PORT_TO_WATCH}" | wc -l)
            ;;
        netstat)
            # netstat: filter for ESTABLISHED state and specified port
            established_count=$(docker exec "$CONTAINER_TO_WATCH" netstat -tn 2>/dev/null | \
                grep "ESTABLISHED" | grep ":${PORT_TO_WATCH}" | wc -l)
            ;;
    esac

    # Check for command execution errors
    if [[ $? -ne 0 ]]; then
        error_exit "Failed to execute connection check command in container"
    fi

    return $established_count
}

# Wait for container to start using Docker events (minimal CPU usage)
wait_for_container_start() {
    log "Waiting for container '$CONTAINER_TO_WATCH' to start (using event listener)..."
    
    # Start docker events in background and save PID
    local event_file="/tmp/watchdog_$$_event"
    rm -f "$event_file"
    
    docker events \
        --filter "type=container" \
        --filter "name=$CONTAINER_TO_WATCH" \
        --filter "event=start" \
        --format '{{.Action}}' 2>/dev/null > "$event_file" &
    
    local event_pid=$!
    
    # Wait for the event file to have content
    while true; do
        if [[ -s "$event_file" ]]; then
            # Event detected, clean up
            kill $event_pid 2>/dev/null
            wait $event_pid 2>/dev/null
            rm -f "$event_file"
            sleep 2
            log "Container '$CONTAINER_TO_WATCH' has started. Grace period: ${STARTUP_GRACE_PERIOD}s before monitoring..."
            sleep "$STARTUP_GRACE_PERIOD"
            log "Resuming connection monitoring..."
            return 0
        fi
        sleep 1
    done
}

# Main watchdog loop
watchdog_loop() {
    local no_connection_start_time=0
    local last_state="unknown"

    while true; do
        # Check if container is running
        if ! container_is_running; then
            # Container not running, reset state and switch to event-based waiting
            if [[ "$last_state" != "stopped" ]]; then
                log "Container '$CONTAINER_TO_WATCH' is not running. Watchdog paused."
                last_state="stopped"
                no_connection_start_time=0
            fi
            
            # Use event-based waiting (minimal CPU usage)
            wait_for_container_start
            
            continue
        fi

        # Container is running, check for connections
        check_established_connections
        local connection_count=$?

        if [[ $connection_count -gt 0 ]]; then
            # Active connection detected
            if [[ "$last_state" != "connected" ]]; then
                log "Active connection(s) detected on port $PORT_TO_WATCH"
                last_state="connected"
            fi
            # Reset timeout counter
            no_connection_start_time=0
        else
            # No active connection
            if [[ "$last_state" != "disconnected" ]]; then
                log "No active connections detected on port $PORT_TO_WATCH. Starting timeout timer..."
                last_state="disconnected"
                no_connection_start_time=$(date +%s)
            fi

            # Check if timeout has been reached
            local current_time=$(date +%s)
            local elapsed=$((current_time - no_connection_start_time))

            if [[ $elapsed -ge $TIMEOUT ]]; then
                log "Timeout reached after ${elapsed}s. Stopping container '$CONTAINER_TO_WATCH'..."
                
                if ! docker stop "$CONTAINER_TO_WATCH" &> /dev/null; then
                    error_exit "Failed to stop container '$CONTAINER_TO_WATCH'"
                fi
                
                log "Container '$CONTAINER_TO_WATCH' stopped successfully."
                last_state="stopped"
                no_connection_start_time=0
            fi
        fi

        # Efficient sleep: use shorter intervals when timeout is approaching
        local sleep_time="$CHECK_INTERVAL"
        if [[ $no_connection_start_time -gt 0 ]]; then
            local remaining=$((TIMEOUT - elapsed))
            # Use smaller intervals as we approach timeout for precision
            if [[ $remaining -lt $((CHECK_INTERVAL * 2)) && $remaining -gt 0 ]]; then
                sleep_time=$((remaining / 2))
                [[ $sleep_time -lt 1 ]] && sleep_time=1
            fi
        fi

        sleep "$sleep_time"
    done
}

################################################################################
# Main Execution
################################################################################

# Validate configuration
validate_config

# Verify container exists
if ! container_exists; then
    error_exit "Container '$CONTAINER_TO_WATCH' does not exist"
fi

log "Watchdog started for container '$CONTAINER_TO_WATCH' on port $PORT_TO_WATCH"
log "Configuration: COMMAND=$COMMAND, TIMEOUT=${TIMEOUT}s, CHECK_INTERVAL=${CHECK_INTERVAL}s, STARTUP_GRACE_PERIOD=${STARTUP_GRACE_PERIOD}s"

# Start watchdog loop
watchdog_loop