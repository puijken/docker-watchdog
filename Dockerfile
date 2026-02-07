FROM python:3.11-alpine

# Install dependencies
RUN apk add --no-cache bash docker-cli iproute2

WORKDIR /app

# Create non-root user (without adding to docker group)
RUN addgroup -g 1000 flask && adduser -D -u 1000 -G flask flask

# Copy files with correct ownership
COPY --chown=flask:flask app.py watchdog.sh /app/
RUN chmod +x /app/watchdog.sh

# Switch to non-root user
USER flask

# Install Python dependencies
RUN pip install --user --no-cache-dir flask

# Set environment variables
ENV PATH="/home/flask/.local/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

CMD ["sh", "-c", "python -m flask run --host=0.0.0.0 & /app/watchdog.sh & wait"]