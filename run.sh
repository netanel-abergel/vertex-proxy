#!/bin/bash
# Kill any existing proxy on port 4100
fuser -k 4100/tcp 2>/dev/null
sleep 1

cd /opt/ocana/bifrost
export GOOGLE_APPLICATION_CREDENTIALS=/opt/ocana/openclaw/gcp-adc.json

while true; do
  fuser -k 4100/tcp 2>/dev/null
  sleep 1
  node proxy.js
  echo "Proxy exited at $(date), restarting in 3s..."
  sleep 3
done
