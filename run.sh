#!/bin/bash
# Auto-restart wrapper for Vertex AI proxy
# Works on both Linux and macOS
# Includes crash guard: stops after 5 rapid crashes within 60 seconds

MAX_CRASHES=5
CRASH_WINDOW=60
PORT="${PROXY_PORT:-4100}"
MAX_LOG_SIZE=10485760  # 10 MB
LOG_FILE="/opt/ocana/bifrost/proxy.log"

kill_port() {
  if command -v fuser &>/dev/null; then
    fuser -k "${PORT}/tcp" 2>/dev/null
  else
    lsof -ti :"${PORT}" | xargs kill 2>/dev/null
  fi
}

rotate_log() {
  if [ -f "$LOG_FILE" ]; then
    local size
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
      mv "$LOG_FILE" "${LOG_FILE}.1"
      echo "[$(date)] Log rotated (was ${size} bytes)" > "$LOG_FILE"
    fi
  fi
}

kill_port
sleep 1

cd /opt/ocana/bifrost
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-/opt/ocana/openclaw/gcp-adc.json}"

crash_times=()

while true; do
  rotate_log
  kill_port
  sleep 1
  node proxy.js
  exit_code=$?
  now=$(date +%s)

  echo "Proxy exited (code $exit_code) at $(date), restarting in 3s..."

  # Track crash times within the window
  crash_times+=("$now")
  # Remove crashes older than CRASH_WINDOW
  recent=()
  for t in "${crash_times[@]}"; do
    if [ $((now - t)) -le "$CRASH_WINDOW" ]; then
      recent+=("$t")
    fi
  done
  crash_times=("${recent[@]}")

  if [ "${#crash_times[@]}" -ge "$MAX_CRASHES" ]; then
    echo "FATAL: $MAX_CRASHES crashes in ${CRASH_WINDOW}s. Stopping. Check proxy.log for errors."
    exit 1
  fi

  sleep 3
done
