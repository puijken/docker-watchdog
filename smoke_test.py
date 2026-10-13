#!/usr/bin/env python3
"""Smoke test for the built image: the real proxy and watchdog against a real Docker daemon.

    python3 smoke_test.py IMAGE

`docker build` proves nothing about runtime. A base-image or dependency bump can still build
cleanly while Flask fails to start, the bundled docker CLI no longer talks to the daemon, or
watchdog.sh never stops anything. This drives one full on-demand cycle instead:

  1. a request to the proxy starts the stopped target and redirects to TARGET_URL;
  2. an open connection to the target's watched port keeps it running past TIMEOUT;
  3. once that connection closes, the watchdog stops the target;
  4. a second request starts it again and the watchdog stops it again (the loop re-arms).

Needs a Docker daemon and nothing else -- stdlib only, and the target is the image under test
itself running `python3 -m http.server`, so no other image is pulled. Containers are removed
afterwards whatever the outcome.
"""
import http.client
import os
import socket
import subprocess
import sys
import time

TAG = f"dwsmoke-{os.getpid()}"
TARGET = f"{TAG}-target"
WATCHDOG = f"{TAG}-watchdog"
PORT = 8080
TARGET_URL = "http://target.example.test/"
TIMEOUT = 6
DOCKER_SOCK = "/var/run/docker.sock"


class SmokeFailure(Exception):
    pass


def docker(*args, check=True):
    result = subprocess.run(["docker", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SmokeFailure(f"docker {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def host_port(container, port):
    """The 127.0.0.1 port Docker published `port` on (assigned only once the container runs)."""
    return int(docker("port", container, str(port)).splitlines()[0].rsplit(":", 1)[1])


def is_running(container):
    return docker("inspect", "-f", "{{.State.Running}}", container) == "true"


def logs(container):
    result = subprocess.run(["docker", "logs", container], capture_output=True, text=True)
    return result.stdout + result.stderr


def wait_for(what, condition, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition():
            return
        time.sleep(0.5)
    raise SmokeFailure(f"timed out after {timeout}s waiting for {what}")


def can_connect(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        return True
    except OSError:
        return False


def request_proxy(port):
    """GET / on the proxy, without following the redirect."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=45)
    try:
        conn.request("GET", "/")
        resp = conn.getresponse()
        return resp.status, resp.getheader("Location")
    finally:
        conn.close()


def check_request_starts_target(proxy_port, which):
    if is_running(TARGET):
        raise SmokeFailure(f"{which}: target already running before the request")
    status, location = request_proxy(proxy_port)
    if (status, location) != (307, TARGET_URL):
        raise SmokeFailure(f"{which}: proxy answered {status} -> {location!r}, "
                           f"expected 307 -> {TARGET_URL!r}")
    if not is_running(TARGET):
        raise SmokeFailure(f"{which}: proxy redirected but the target is not running")
    print(f"  {which}: proxy started the stopped target and redirected (307)")


def check_open_connection_keeps_target(proxy_port):
    target_port = host_port(TARGET, PORT)
    wait_for("the target to listen", lambda: can_connect(target_port), 10)
    held = socket.create_connection(("127.0.0.1", target_port), timeout=5)
    try:
        wait_for("the watchdog to see the open connection",
                 lambda: "Active connection(s) detected" in logs(WATCHDOG), 20)
        time.sleep(TIMEOUT + 4)
        if not is_running(TARGET):
            raise SmokeFailure("watchdog stopped the target while a connection was open")
    finally:
        held.close()
    print(f"  open connection: target kept running past TIMEOUT ({TIMEOUT}s)")


def check_idle_stops_target(which):
    wait_for(f"the watchdog to stop the idle target ({which})",
             lambda: not is_running(TARGET), TIMEOUT + 20)
    print(f"  {which}: watchdog stopped the idle target")


def run(image):
    sock_gid = os.stat(DOCKER_SOCK).st_gid

    # --stop-timeout: http.server as PID 1 ignores SIGTERM, so `docker stop` would otherwise
    # wait the full 10s default before killing it.
    docker("create", "--name", TARGET, "--stop-timeout", "2", "-p", f"127.0.0.1::{PORT}",
           image, "python3", "-m", "http.server", str(PORT))

    # Same shape as a real deployment: non-root, with the socket's group added (the image does
    # not join a docker group itself).
    docker("run", "-d", "--name", WATCHDOG, "--user", f"1000:{sock_gid}",
           "-v", f"{DOCKER_SOCK}:{DOCKER_SOCK}", "-p", "127.0.0.1::5000",
           "-e", f"CONTAINER_TO_WATCH={TARGET}", "-e", f"PORT_TO_WATCH={PORT}",
           "-e", f"TARGET_URL={TARGET_URL}", "-e", f"TIMEOUT={TIMEOUT}",
           "-e", "CHECK_INTERVAL=1", "-e", "STARTUP_GRACE_PERIOD=1", image)

    proxy_port = host_port(WATCHDOG, 5000)
    wait_for("the proxy to listen", lambda: can_connect(proxy_port), 20)
    # watchdog.sh subscribes to start events only after it has seen the target stopped; a start
    # before that would go unnoticed.
    wait_for("watchdog.sh to arm", lambda: "Watchdog paused" in logs(WATCHDOG), 20)
    time.sleep(1)

    check_request_starts_target(proxy_port, "first request")
    check_open_connection_keeps_target(proxy_port)
    check_idle_stops_target("after the connection closed")
    check_request_starts_target(proxy_port, "second request")
    check_idle_stops_target("re-armed loop")

    if not is_running(WATCHDOG):
        raise SmokeFailure("watchdog container exited")
    if "ERROR" in logs(WATCHDOG):
        raise SmokeFailure("watchdog logged an ERROR")


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    try:
        run(sys.argv[1])
    except SmokeFailure as e:
        print(f"\nSMOKE TEST FAILED: {e}\n\n--- watchdog logs ---\n{logs(WATCHDOG)}",
              file=sys.stderr)
        return 1
    finally:
        docker("rm", "-f", WATCHDOG, TARGET, check=False)

    print("smoke test passed: start on request, kept alive by a connection, idle stop, re-arm")
    return 0


if __name__ == "__main__":
    sys.exit(main())
