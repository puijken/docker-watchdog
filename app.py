from flask import Flask, redirect, request
import os
import subprocess
import time
from datetime import datetime
import logging
import sys

CONTAINER_TO_WATCH = os.getenv("CONTAINER_TO_WATCH", "webtop")
TARGET_URL = os.getenv("TARGET_URL", "http://redirect.to")
STARTUP_GRACE_PERIOD = int(os.getenv("STARTUP_GRACE_PERIOD", "5"))

app = Flask(__name__)

# Disable Flask's default logging
log_werkzeug = logging.getLogger('werkzeug')
log_werkzeug.setLevel(logging.ERROR)

# Disable output buffering
sys.stdout = open(sys.stdout.fileno(), mode='w', buffering=1, encoding='utf8')
sys.stderr = open(sys.stderr.fileno(), mode='w', buffering=1, encoding='utf8')

# Cache last startup time
_container_start_time = None
_last_check_time = None
_startup_logged = False

def log(message):
    """Log with [FLASK: timestamp] format"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f"[FLASK: {timestamp}] {message}", flush=True)

def is_container_running(container_name):
    """Check if container is running - minimal subprocess call"""
    try:
        result = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", container_name],
            capture_output=True,
            text=True,
            timeout=5
        )
        return result.stdout.strip() == "true"
    except (subprocess.TimeoutExpired, Exception):
        log(f"ERROR: Failed to check container '{container_name}' status")
        return False

def start_container(container_name):
    """Start the container - only called when needed"""
    try:
        log(f"Starting container '{container_name}'...")
        subprocess.run(["docker", "start", container_name], timeout=10, capture_output=True)
        log(f"Container '{container_name}' start command issued")
    except (subprocess.TimeoutExpired, Exception) as e:
        log(f"ERROR: Failed to start container '{container_name}': {str(e)}")

def wait_for_container_start(container_name, max_wait=30):
    """
    Wait for container to start using Docker events (minimal CPU/memory)
    Only called during initial startup
    """
    log(f"Waiting for container '{container_name}' to start (max {max_wait}s)...")
    start_time = time.time()
    event_file = f"/tmp/container_start_{os.getpid()}.tmp"
    
    proc = None
    try:
        with open(event_file, 'w') as f:
            proc = subprocess.Popen(
                [
                    "docker", "events",
                    "--filter", "type=container",
                    "--filter", f"name={container_name}",
                    "--filter", "event=start",
                    "--format", "{{.Action}}"
                ],
                stdout=f,
                stderr=subprocess.DEVNULL
            )
    except Exception as e:
        log(f"ERROR: Failed to start Docker events listener: {str(e)}")
    
    while time.time() - start_time < max_wait:
        if os.path.exists(event_file) and os.path.getsize(event_file) > 0:
            try:
                if proc:
                    proc.terminate()
                os.remove(event_file)
            except:
                pass
            elapsed = time.time() - start_time
            log(f"Container '{container_name}' started (detected after {elapsed:.1f}s)")
            return True
        
        if is_container_running(container_name):
            try:
                if proc:
                    proc.terminate()
                os.remove(event_file)
            except:
                pass
            elapsed = time.time() - start_time
            log(f"Container '{container_name}' is running (detected after {elapsed:.1f}s)")
            return True
        
        time.sleep(0.5)
    
    try:
        if proc:
            proc.terminate()
        os.remove(event_file)
    except:
        pass
    
    log(f"ERROR: Container '{container_name}' did not start within {max_wait}s timeout")
    return False

@app.route('/')
def proxy():
    """
    Redirect to target URL after ensuring container is started
    """
    global _container_start_time, _last_check_time, _startup_logged
    
    current_time = time.time()
    
    # FAST PATH 1: Container recently started, within grace period
    if _container_start_time and (current_time - _container_start_time) < STARTUP_GRACE_PERIOD:
        return redirect(TARGET_URL, code=307)
    
    # FAST PATH 2: Recently checked and running (2 second cache)
    if _last_check_time and (current_time - _last_check_time) < 2:
        if is_container_running(CONTAINER_TO_WATCH):
            return redirect(TARGET_URL, code=307)
    else:
        # CHECK: Container check (happens every 2 seconds after grace period)
        _last_check_time = current_time
        if is_container_running(CONTAINER_TO_WATCH):
            return redirect(TARGET_URL, code=307)
    
    # STARTUP PATH: Container not running, initiate startup
    if not _startup_logged:
        log(f"Request received but container offline, initiating startup...")
        _startup_logged = True
    
    start_container(CONTAINER_TO_WATCH)
    
    if wait_for_container_start(CONTAINER_TO_WATCH, max_wait=30):
        _container_start_time = time.time()
        _startup_logged = False
        log(f"Grace period activated ({STARTUP_GRACE_PERIOD}s), waiting before redirect...")
        time.sleep(STARTUP_GRACE_PERIOD)
        log(f"Grace period complete, redirecting to {TARGET_URL}")
        return redirect(TARGET_URL, code=307)
    else:
        _container_start_time = None
        _startup_logged = False
        log(f"ERROR: Startup timeout, returning 503 error")
        return {
            "error": "Container startup timeout",
            "message": f"Container '{CONTAINER_TO_WATCH}' did not start within 30 seconds",
            "container": CONTAINER_TO_WATCH
        }, 503

if __name__ == "__main__":
    log(f"Watchdog app starting - Container: {CONTAINER_TO_WATCH}, Target: {TARGET_URL}, Grace period: {STARTUP_GRACE_PERIOD}s")
    app.run(
        host="0.0.0.0",
        port=5000,
        debug=False,
        use_reloader=False,
        use_debugger=False
    )