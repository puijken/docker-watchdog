from flask import Flask, redirect
import subprocess
import os
import time

app = Flask(__name__)

CONTAINER = os.getenv("TARGET_CONTAINER")
STARTUP_WAIT = int(os.getenv("STARTUP_WAIT", "2"))

if not CONTAINER:
    raise RuntimeError("Environment variable TARGET_CONTAINER must be set.")

def is_container_running(name: str) -> bool:
    result = subprocess.run(
        ["docker", "inspect", "-f", "{{.State.Running}}", name],
        capture_output=True, text=True
    )
    return result.stdout.strip() == "true"

def start_container(name: str):
    subprocess.run(["docker", "start", name], check=False)

@app.route('/')
def proxy():
    if not is_container_running(CONTAINER):
        start_container(CONTAINER)
        time.sleep(STARTUP_WAIT)
    # Redirect to same hostname/URL (Traefik will re-route automatically)
    return redirect("/", code=307)
