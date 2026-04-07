#!/bin/bash
# Vertex AI Proxy Controller for OpenClaw
# Usage: vertex-ctl {start|stop|status|model|test}

# Auto-detect proxy dir: resolve symlink, then go up from scripts/
PROXY_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")" && cd .. && pwd)"
OC_CONF="/opt/ocana/openclaw/openclaw.json"
AGENT_MODELS="/opt/ocana/openclaw/agents/main/agent/models.json"
AUTH_PROFILES="/opt/ocana/openclaw/agents/main/agent/auth-profiles.json"
SESSIONS="/opt/ocana/openclaw/agents/main/sessions/sessions.json"
GCP_CREDS="/opt/ocana/openclaw/gcp-adc.json"
PORT="${PROXY_PORT:-4100}"

# Temp file management — use mktemp and clean up on exit
TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

safe_jq_update() {
  local filter="$1" src="$2"
  local tmp
  tmp=$(mktemp)
  TMPFILES+=("$tmp")
  if jq "$filter" "$src" > "$tmp" 2>/dev/null; then
    cp "$tmp" "$src"
  else
    echo "✗ Failed to update $src"
    return 1
  fi
}

kill_proxy() {
  pkill -f "vertex-proxy/scripts/run.sh" 2>/dev/null
  pkill -f "vertex-proxy/src/proxy.js" 2>/dev/null
  if command -v fuser &>/dev/null; then
    fuser -k "${PORT}/tcp" 2>/dev/null
  else
    lsof -ti :"${PORT}" | xargs kill 2>/dev/null
  fi
}

enable_proxy() {
  safe_jq_update "(.models.providers.anthropic.baseUrl) = \"http://localhost:${PORT}\" | (.models.providers.anthropic.apiKey) = \"vertex-proxy\"" "$OC_CONF"
  safe_jq_update "(.providers.anthropic.baseUrl) = \"http://localhost:${PORT}\" | (.providers.anthropic.apiKey) = \"vertex-proxy\"" "$AGENT_MODELS"
  safe_jq_update ".[\"anthropic:manual\"] = {\"provider\":\"anthropic\",\"token\":\"vertex-proxy\",\"profileId\":\"anthropic:manual\"}" "$AUTH_PROFILES"
}

disable_proxy() {
  safe_jq_update '(.models.providers.anthropic.baseUrl) = "https://api.anthropic.com" | (.models.providers.anthropic.apiKey) = ""' "$OC_CONF"
  safe_jq_update '(.providers.anthropic.baseUrl) = "https://api.anthropic.com" | (.providers.anthropic.apiKey) = ""' "$AGENT_MODELS"
  safe_jq_update 'del(.["anthropic:manual"])' "$AUTH_PROFILES"
}

get_session_model() {
  jq -r '[.. | .model? // empty] | map(select(. != null and . != "")) | group_by(.) | sort_by(-length) | .[0][0] // "unknown"' "$SESSIONS" 2>/dev/null
}

case "$1" in
  start)
    if [ ! -f "$GCP_CREDS" ]; then
      echo "✗ GCP credentials not found at $GCP_CREDS"
      echo "  Copy your application_default_credentials.json there first."
      echo "  Generate with: gcloud auth application-default login"
      exit 1
    fi

    echo "Starting Vertex AI proxy..."
    kill_proxy
    sleep 1

    nohup "$PROXY_DIR/scripts/run.sh" >> "$PROXY_DIR/proxy.log" 2>&1 &
    sleep 4

    if curl -s -m 3 "http://localhost:${PORT}/" | grep -q vertex; then
      enable_proxy
      echo "✓ Proxy running on port ${PORT}"
      echo "✓ OpenClaw pointed to Vertex AI"
      echo "  Restart gateway to apply"
    else
      echo "✗ Proxy failed to start. Check $PROXY_DIR/proxy.log"
    fi
    ;;
  stop)
    echo "Stopping Vertex AI proxy..."
    kill_proxy
    disable_proxy
    echo "✓ Proxy stopped"
    echo "✓ OpenClaw reverted to default provider"
    echo "  Restart gateway to apply"
    ;;
  status)
    if curl -s -m 2 "http://localhost:${PORT}/health" | grep -q vertex; then
      echo "✓ Proxy: RUNNING (port ${PORT})"
      # Show health details if available
      HEALTH=$(curl -s -m 2 "http://localhost:${PORT}/health")
      ACTIVE=$(echo "$HEALTH" | jq -r '.activeRequests // 0' 2>/dev/null)
      UPTIME=$(echo "$HEALTH" | jq -r '.uptime // 0' 2>/dev/null)
      REGION_INFO=$(echo "$HEALTH" | jq -r '.region // "unknown"' 2>/dev/null)
      echo "  Region: ${REGION_INFO}"
      echo "  Active requests: ${ACTIVE}"
      echo "  Uptime: ${UPTIME}s"
    else
      echo "✗ Proxy: DOWN"
    fi
    SESSION_MODEL=$(get_session_model)
    CURRENT_URL=$(jq -r '.models.providers.anthropic.baseUrl' "$OC_CONF" 2>/dev/null)
    echo "  Model: ${SESSION_MODEL}"
    echo "  Route: ${CURRENT_URL}"
    if [ ! -f "$GCP_CREDS" ]; then
      echo "  ⚠ GCP credentials missing: $GCP_CREDS"
    fi
    ;;
  test)
    echo "Testing proxy with claude-sonnet-4-6..."
    if ! curl -s -m 2 "http://localhost:${PORT}/" | grep -q vertex; then
      echo "✗ Proxy is not running. Run: vertex-ctl start"
      exit 1
    fi
    RESPONSE=$(curl -s -m 30 -X POST "http://localhost:${PORT}/v1/messages" \
      -H "Content-Type: application/json" \
      -d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"say hi"}]}')
    if echo "$RESPONSE" | grep -q '"text"'; then
      echo "✓ Proxy working! Response:"
      echo "$RESPONSE" | jq -r '.content[0].text' 2>/dev/null || echo "$RESPONSE"
    else
      echo "✗ Proxy returned error:"
      echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
      echo ""
      echo "Common fixes:"
      echo "  invalid_grant → GCP token expired. Run: gcloud auth application-default login"
      echo "                  Then copy ~/.config/gcloud/application_default_credentials.json to $GCP_CREDS"
      echo "                  Then: vertex-ctl start"
    fi
    ;;
  model)
    if [ -z "$2" ]; then
      echo "Available models:"
      echo "  claude-sonnet-4-6"
      echo "  claude-opus-4-6"
      echo "  claude-haiku-4-5"
      echo ""
      SESSION_MODEL=$(get_session_model)
      echo "Current: ${SESSION_MODEL}"
      echo ""
      echo "Usage: vertex-ctl model <model-name>"
      exit 0
    fi
    NEW_MODEL="$2"
    OLD_MODEL=$(get_session_model)
    if [ "$OLD_MODEL" = "unknown" ] || [ -z "$OLD_MODEL" ]; then
      echo "✗ Could not detect current model in sessions"
      exit 1
    fi
    # Update sessions using jq for safe structured replacement
    safe_jq_update "walk(if type == \"string\" and . == \"${OLD_MODEL}\" then \"${NEW_MODEL}\" else . end)" "$SESSIONS"
    COUNT=$(jq "[.. | strings | select(. == \"${NEW_MODEL}\")] | length" "$SESSIONS" 2>/dev/null)
    openclaw models set "anthropic/${NEW_MODEL}" 2>&1 | tail -1
    echo "✓ Model switched: ${OLD_MODEL} → ${NEW_MODEL} (${COUNT} refs)"
    echo "  Restart gateway to apply"
    ;;
  *)
    echo "Vertex AI Proxy Controller"
    echo ""
    echo "Usage: vertex-ctl {start|stop|status|model|test}"
    echo ""
    echo "  start          Start proxy, point OpenClaw to Vertex AI"
    echo "  stop           Stop proxy, revert to default provider"
    echo "  status         Show proxy status and current model"
    echo "  model          Show current model"
    echo "  model <name>   Switch model (e.g. claude-opus-4-6)"
    echo "  test           Send a test message through the proxy"
    exit 1
    ;;
esac
