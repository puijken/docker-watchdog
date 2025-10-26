# 🐋 Docker Watchdog — Auto-Start & Auto-Stop Container Manager

A lightweight Flask + Shell-based “watchdog” that automatically **starts**, **monitors**, and **stops** Docker containers based on user activity.  
Designed to work seamlessly behind **Traefik** (or any reverse proxy), this container ensures your heavy apps only run when they’re actually in use.

---

## 🚀 Features

- 💤 **Auto-start**: When a user accesses the app hostname, the watchdog starts the target container.
- 🕒 **Auto-stop**: When the target container is idle for a defined period, it’s stopped to save resources.
- 🔧 **Fully configurable** via environment variables — no hardcoded names or ports.
- 🧠 **Graceful shutdown**: If the watchdog container stops, the target container is stopped too.
- 💡 **Traefik-ready**: Both watchdog and target containers share the same hostname; Traefik routes to whichever is active.
- ⚙️ **Low-resource footprint**: Minimal Flask app + small shell loop using Alpine Linux.

---

## 🏗️ Architecture Overview

         ┌────────────────────────────┐
         │        Traefik Proxy       │
         │        (webtop.example)    │
         └──────────────┬─────────────┘
                        │
              ┌─────────┴──────────┐
              │  Watchdog Container │
              │  (Flask + Shell)   │
              ├────────────────────┤
              │ - Starts container │
              │ - Detects activity │
              │ - Stops on idle    │
              └─────────┬──────────┘
                        │
         ┌──────────────┴────────────┐
         │ Target App (e.g. Webtop)  │
         │ Runs only when in use     │
         └───────────────────────────┘

---

## 🧰 Configuration

All behavior is controlled via environment variables:

| Variable | Required | Default | Description |
|-----------|-----------|----------|--------------|
| `TARGET_CONTAINER` | ✅ | – | Name of the Docker container to monitor (must exist). |
| `STARTUP_WAIT` | ❌ | `2` | Seconds to wait after starting the target container before redirecting (allows Traefik to detect it). |
| `CHECK_INTERVAL` | ❌ | `60` | How often (in seconds) to check for activity. |
| `IDLE_LIMIT` | ❌ | `900` | How long (in seconds) the container can remain idle before being stopped. |
| `CHECK_CMD` | ✅ | – | Command to run **inside** the target container to detect activity (e.g. active connections). Must return output when active. |

---

## 🧩 Example: Watchdog for Webtop

### `docker-compose.yml`

```yaml
version: "3.9"

services:
  webtop-watchdog:
    image: ghcr.io/yourusername/docker-watchdog:latest
    environment:
      - TARGET_CONTAINER=webtop
      - STARTUP_WAIT=3
      - CHECK_INTERVAL=60
      - IDLE_LIMIT=900
      - CHECK_CMD=ss -tn state established '( sport = :3001 )'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.webtop.rule=Host(`webtop.example.com`)"
      - "traefik.http.services.webtop.loadbalancer.server.port=5000"
    restart: unless-stopped

  webtop:
    image: lscr.io/linuxserver/webtop:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.webtop.rule=Host(`webtop.example.com`)"
    restart: unless-stopped
