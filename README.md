# Docker Watchdog

A dual-purpose container management tool that combines a Flask proxy with a background watchdog script to automatically start containers on-demand and stop them after inactivity.

## 📋 Table of Contents

- [Features](#features)
- [Use Cases](#use-cases)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Environment Variables](#environment-variables)
- [Docker Compose Examples](#docker-compose-examples)
- [Security](#security)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)

---

## ✨ Features

- **On-Demand Container Startup**: Automatically starts your target container when a request is received
- **Automatic Shutdown**: Stops containers after a configurable timeout period with no active connections
- **Dual Monitoring**: Both Flask proxy and watchdog script work together for robust operation
- **Efficient Event Monitoring**: Uses Docker events API for minimal CPU/memory overhead
- **Connection Detection**: Monitors active connections on a specific port using `ss` or `netstat`
- **Graceful Startup**: Configurable grace period after container start before redirecting traffic
- **Non-Root User**: Runs as non-root user for improved security
- **Resource Limits**: Easy to configure CPU and memory constraints
- **Production Ready**: Built-in error handling and logging
- **Traefik Integration**: Use Traefik loadbalancer priority to use a single URL

---

## 🎯 Use Cases

### 1. **Cost Optimization**
Stop expensive containers when not in use, start them automatically on demand.

```
User Request → Watchdog starts container → User redirected → Container runs
↓ (after timeout with no activity)
Container stopped → Resources freed → Cost reduced
```

### 2. **Development Environment**
Keep development containers dormant until needed, reducing resource consumption.

### 3. **Demo/Testing Environments**
Automatically manage resource-heavy demo applications that are only used occasionally.

### 4. **Multi-Tenant Applications**
Manage multiple containers with individual on-demand startup/shutdown behavior.

---

## 🏗️ Architecture

Docker Watchdog consists of two components working together:

### Component 1: Flask Proxy (Port 5000)
- Receives incoming requests
- Checks if target container is running
- Starts container if offline
- Waits for startup completion
- Redirects user to target URL

### Component 2: Watchdog Script
- Monitors active connections on specified port
- Tracks idle time
- Stops container after timeout with no connections
- Uses Docker events for efficient monitoring

```
Incoming Request
    ↓
Flask Proxy (5000)
    ├─→ Container Running? 
    │   ├─ YES → Redirect to target URL
    │   └─ NO → Start container → Wait → Redirect
    ↓
Target Container (e.g., port 3001)
    ↓
Watchdog Script
    └─→ Monitor connections
        ├─ Active connections? → Keep running
        └─ Idle for X seconds? → Stop container
```

---

## 🚀 Quick Start

## ⚙️ Configuration

### Environment Variables

| Variable | Default | Description | Example |
|----------|---------|-------------|---------|
| `CONTAINER_TO_WATCH` | *required* | Name of container to manage | `webtop` |
| `PORT_TO_WATCH` | *required* | Port to monitor for connections | `3001` |
| `TARGET_URL` | *required* | URL to redirect to after startup | `https://webtop.domain.local` |
| `COMMAND` | `ss` | Connection check tool (`ss` or `netstat`) | `netstat` |
| `CHECK_INTERVAL` | `10` | Seconds between connection checks | `60` |
| `TIMEOUT` | `300` | Seconds of inactivity before stopping (5 min) | `600` |
| `STARTUP_GRACE_PERIOD` | `5` | Seconds to wait after startup before redirect | `10` |
| `TZ` | `UTC` | Timezone for logging | `Europe/Amsterdam` |

### Flask Configuration Variables

These are read automatically from environment:
- `CONTAINER_TO_WATCH` — Same as watchdog
- `TARGET_URL` — Same as watchdog
- `STARTUP_GRACE_PERIOD` — Same as watchdog
- `PYTHONUNBUFFERED` — Set to `1` for real-time logging

---

## 📦 Docker Compose Examples

### Example 1: Basic Setup with Traefik

```yaml
version: '3.8'

services:
  watchdog:
    image: ghcr.io/puijken/docker-watchdog:latest
    container_name: watchdog
    environment:
      - TZ=Europe/Amsterdam
      - CONTAINER_TO_WATCH=webtop
      - PORT_TO_WATCH=3001
      - TARGET_URL=https://webtop.domain.local
      - TIMEOUT=600
      - CHECK_INTERVAL=60
      - STARTUP_GRACE_PERIOD=5
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.webtop-watchdog.rule=Host(`webtop.domain.local`)"
      - "traefik.http.services.webtop-watchdog.loadbalancer.server.port=5000"
      - "traefik.http.routers.webtop-watchdog.priority=10"
    restart: always

  webtop:
    image: lscr.io/linuxserver/webtop:latest
    container_name: webtop
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.webtop.rule=Host(`webtop.domain.local`)"
      - "traefik.http.services.webtop.loadbalancer.server.port=3001"
      - "traefik.http.routers.webtop.priority=20"
    restart: unless-stopped
```

---

## 🔒 Security

Docker Watchdog follows security best practices:

### ✅ Security Features Implemented

| Feature | Details |
|---------|---------|
| **Non-Root User** | Runs as UID 1000 (non-root) |
| **Minimal Permissions** | Only requires Docker socket access |
| **Read-Only Filesystem** | Optional configuration available |
| **Capability Dropping** | Drops unnecessary Linux capabilities |
| **Resource Limits** | CPU and memory constraints |
| **Debug Mode Off** | Flask runs in production mode |
| **No Output Buffering** | Real-time logging for monitoring |

### Recommended Security Configuration

Add to your `docker-compose.yml`:

```yaml
watchdog:
  # ... other config
  user: "1000:999"  # Replace 999 with your docker group GID
  read_only: true
  tmpfs:
    - /tmp
    - /home/flask/.cache
  cap_drop:
    - ALL
  cap_add:
    - NET_RAW
```

### Finding Your Docker Group GID

```bash
getent group docker | cut -d: -f3
```

Output: e.g., `999`

---

## 🔍 How It Works

### Request Flow (Container Offline)

```
1. User visits http://watchdog:5000
2. Flask checks: Is CONTAINER_TO_WATCH running?
3. Response: NO
4. Flask: docker start CONTAINER_TO_WATCH
5. Flask: Wait for container to start (using docker events)
6. Watchdog: Detects startup event
7. Flask: Apply grace period (e.g., 5 seconds)
8. Flask: Redirect to TARGET_URL (HTTP 307)
9. User: Connected to target container
10. Watchdog: Monitor active connections
```

### Idle Timeout Flow (No Connections)

```
1. Watchdog: Check for connections on PORT_TO_WATCH
2. Result: 0 active connections
3. Timer: Start idle counter
4. Every CHECK_INTERVAL seconds: Check again
5. After TIMEOUT seconds: No connections detected
6. Action: docker stop CONTAINER_TO_WATCH
7. Status: Container stopped, resources freed
8. Next request: Repeat from step 1
```

### Connection Monitoring

The watchdog monitors **established connections** using either:

- **`ss` command** (faster, modern): 
  ```bash
  ss -tn | grep ESTAB | grep :PORT
  ```

- **`netstat` command** (fallback):
  ```bash
  netstat -tn | grep ESTABLISHED | grep :PORT
  ```

---

## 📊 Logging

Both components log with timestamp prefixes for easy identification:

```
[FLASK: 2024-01-15 14:23:45] Request received but container offline, initiating startup...
[FLASK: 2024-01-15 14:23:47] Container 'webtop' started (detected after 1.3s)
[FLASK: 2024-01-15 14:23:52] Grace period complete, redirecting to https://webtop.domain.local

[WATCHDOG: 2024-01-15 14:23:52] Container 'webtop' has started.
[WATCHDOG: 2024-01-15 14:24:00] Active connection(s) detected on port 3001
[WATCHDOG: 2024-01-15 14:34:00] No active connections detected. Starting timeout timer...
[WATCHDOG: 2024-01-15 14:44:00] Timeout reached after 600s. Stopping container 'webtop'...
```

View logs:

```bash
docker-compose logs -f watchdog
```

---

## 🔧 Troubleshooting

### Issue: "Container does not exist" error

**Solution**: Ensure your target container is defined in the same `docker-compose.yml`:

```yaml
services:
  watchdog:
    # ... watchdog config
    depends_on:
      target-container:
        condition: service_started
  
  target-container:
    image: your/image:latest
    restart: unless-stopped
```

### Issue: Permission denied accessing Docker socket

**Solution**: Set the correct Docker group GID in your compose file:

```bash
# Find your docker GID
getent group docker | cut -d: -f3

# Use it in docker-compose.yml
user: "1000:999"  # Replace 999 with your GID
```

### Issue: Container not stopping after timeout

**Causes**:
- Connections not detected correctly (wrong PORT_TO_WATCH)
- Application using different port than expected
- Firewall blocking connection detection

**Solution**:
1. Verify port with: `docker exec CONTAINER ss -tlnp`
2. Check watchdog logs: `docker-compose logs watchdog`
3. Increase CHECK_INTERVAL for more reliable detection

### Issue: Flask not redirecting to target URL

**Causes**:
- Container not fully started (increase STARTUP_GRACE_PERIOD)
- Target URL incorrect
- Container crashes on startup

**Solution**:
```yaml
environment:
  STARTUP_GRACE_PERIOD: 15  # Increase from default 5
```

Check logs:
```bash
docker-compose logs watchdog | grep -E "ERROR|Grace period"
```

### Issue: High CPU usage

**Causes**:
- CHECK_INTERVAL too low
- Docker socket operations inefficient

**Solution**:
```yaml
environment:
  CHECK_INTERVAL: 60  # Increase from default 10
```

---

## 📝 Advanced Configuration

### Custom Connection Check Command

Switch from `ss` to `netstat`:

```yaml
environment:
  COMMAND: netstat  # Options: "ss" or "netstat"
```

### Extended Timeout for Slow Applications

```yaml
environment:
  TIMEOUT: 3600  # 1 hour instead of 5 minutes
  CHECK_INTERVAL: 120  # Check every 2 minutes
```

### Faster Startup Detection

```yaml
environment:
  STARTUP_GRACE_PERIOD: 2  # Redirect after 2 seconds instead of 5
```

---

## 📄 License

This project is provided as-is. See LICENSE file for details.

---

## 🤝 Contributing

Contributions welcome! Please submit issues and pull requests.

---

## 📞 Support

For issues, questions, or suggestions, please open an issue on GitHub.