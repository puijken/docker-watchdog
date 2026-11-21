FROM python:3.15-alpine

# Install dependencies
RUN apk add --no-cache bash docker-cli iproute2

WORKDIR /app

# Create non-root user (without adding to docker group)
RUN addgroup -g 1000 flask && adduser -D -u 1000 -G flask flask

# Copy files with correct ownership
COPY --chown=flask:flask app.py watchdog.sh entrypoint.sh /app/
RUN chmod +x /app/watchdog.sh /app/entrypoint.sh

# Switch to non-root user
USER flask

# Install Python dependencies
RUN pip install --user --no-cache-dir flask

# Set environment variables
ENV PATH="/home/flask/.local/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Runs the proxy and the watchdog loop, ends the container when either exits, handles SIGTERM.
CMD ["/app/entrypoint.sh"]