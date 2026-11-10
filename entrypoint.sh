#!/bin/bash

################################################################################
# Container entrypoint: runs the proxy and the watchdog loop side by side.
#
# The container is only useful with both. This script ends it as soon as either
# one ends, so Docker's restart policy brings the pair back. Before this, the
# command was `app.py & watchdog.sh & wait`, which waits for *both*: when the
# watchdog loop died the proxy kept answering, the container stayed "Up", and
# the watched container was simply never stopped again.
#
# It also handles SIGTERM. A shell running as PID 1 ignores signals it has no
# handler for, so `docker stop` used to wait out its full grace period (10s by
# default) and then kill the container.
################################################################################

log() {
    echo "[ENTRYPOINT: $(date +'%Y-%m-%d %H:%M:%S')] $1"
}

python3 /app/app.py &
/app/watchdog.sh &

stop_children() {
    # shellcheck disable=SC2046  # word splitting is wanted: one PID per job
    kill -TERM $(jobs -p) 2>/dev/null
    wait
}

trap 'log "Stop requested, shutting down"; stop_children; exit 0' TERM INT

# Returns when the first of the two exits. A trapped signal interrupts it too, but then the
# trap above runs and exits before the lines below are reached.
wait -n
status=$?

log "ERROR: the proxy or the watchdog loop exited (status $status). Stopping the container so both are restarted together."
stop_children
exit 1
