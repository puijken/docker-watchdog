# Use a specific Python version with Alpine for minimal footprint
FROM python:3-alpine

# Upgrade Alpine packages and install required tools
RUN apk update && apk upgrade && \
    apk add --no-cache docker-cli iproute2 bash

# Set working directory
WORKDIR /app

# Copy application files
COPY app.py watchdog.sh /app/

# Ensure watchdog script is executable
RUN chmod +x /app/watchdog.sh

# Install Python dependencies
RUN pip install --no-cache-dir flask

# Define environment variables
ENV TARGET_CONTAINER="" \
    STARTUP_WAIT=2 \
    CHECK_INTERVAL=60 \
    IDLE_LIMIT=900 \
    CHECK_CMD=""

# Run Flask and watchdog concurrently
CMD ["sh", "-c", "flask run --host=0.0.0.0 & /app/watchdog.sh & wait"]