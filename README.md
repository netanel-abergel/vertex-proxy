# Vertex AI Proxy for OpenClaw

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Node.js](https://img.shields.io/badge/node-%3E%3D18-green)](https://nodejs.org)
[![GCP](https://img.shields.io/badge/GCP-Vertex%20AI-4285F4)](https://cloud.google.com/vertex-ai)

Translates Anthropic API requests to Google Cloud Vertex AI, allowing OpenClaw to use Claude models via your GCP project. The proxy passes through the model name from each request — no hardcoded model.

## Why a proxy?

OpenClaw's built-in `anthropic-vertex` provider requires a different model naming scheme and auth flow. This proxy lets you keep using the standard `anthropic` provider — same model names, same API format — while routing through Vertex AI under the hood. No OpenClaw configuration changes beyond pointing `baseUrl` to localhost.

## Architecture

```
OpenClaw (anthropic provider, baseUrl → localhost:4100)
  → http://localhost:4100 (Node.js proxy)
    → @anthropic-ai/vertex-sdk
      → Vertex AI (primary region)
        → Claude model from request (e.g. claude-sonnet-4-6)
      → Vertex AI (fallback region, on 5xx)
```

**Key concept:** OpenClaw uses the `anthropic` provider (NOT `anthropic-vertex`) with `baseUrl` pointed to the local proxy. The proxy translates the standard Anthropic API format to Vertex AI. The model name is taken from the request, not hardcoded.

## Prerequisites

1. **GCP ADC credentials** — generate with:
   ```bash
   gcloud auth application-default login --project devex-ai
   ```
   This creates `~/.config/gcloud/application_default_credentials.json`

2. **Node.js** (v18+) installed on the Ocana machine

## Setup

```bash
# On the Ocana machine (Linux or macOS):
mkdir -p /opt/ocana/bifrost
cp proxy.js run.sh package.json /opt/ocana/bifrost/
cp vertex-ctl.sh /usr/local/bin/vertex-ctl
chmod +x /opt/ocana/bifrost/run.sh /usr/local/bin/vertex-ctl
cd /opt/ocana/bifrost && npm install

# Copy GCP ADC credentials to the Ocana machine:
cp ~/.config/gcloud/application_default_credentials.json /opt/ocana/openclaw/gcp-adc.json
```

## Quick Start

```bash
vertex-ctl start              # Start proxy + configure OpenClaw
vertex-ctl test               # Verify it works end-to-end
openclaw gateway restart       # Apply changes
```

## Commands

| Command | What it does |
|---------|-------------|
| `vertex-ctl start` | Starts proxy, points OpenClaw anthropic provider to `localhost:4100` |
| `vertex-ctl stop` | Stops proxy, reverts OpenClaw to `api.anthropic.com` |
| `vertex-ctl status` | Shows proxy status, current model, region, active requests, uptime |
| `vertex-ctl test` | Sends a test message through the proxy to verify it works |
| `vertex-ctl model` | Shows current model and available options |
| `vertex-ctl model <name>` | Switch model (e.g. `claude-sonnet-4-6`, `claude-opus-4-6`) |

After `start`, `stop`, or `model`, restart the gateway:
```bash
openclaw gateway restart
```

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VERTEX_PROJECT_ID` | `devex-ai` | GCP project ID |
| `VERTEX_REGION` | `us-east5` | Primary Vertex AI region |
| `VERTEX_FALLBACK_REGION` | `us-central1` | Fallback region (used on 5xx errors) |
| `PROXY_PORT` | `4100` | Port the proxy listens on |
| `VERTEX_MAX_CONCURRENT` | `20` | Max concurrent requests (returns 429 when exceeded) |
| `VERTEX_DEBUG` | `0` | Set to `1` for verbose logging (request sizes, latency) |
| `GOOGLE_APPLICATION_CREDENTIALS` | `/opt/ocana/openclaw/gcp-adc.json` | Path to GCP ADC credentials |

Example:
```bash
VERTEX_PROJECT_ID=my-project VERTEX_REGION=europe-west1 vertex-ctl start
```

## How it works

1. `vertex-ctl start` does three things:
   - Starts the proxy on the configured port (via `run.sh`)
   - Updates OpenClaw's `anthropic` provider `baseUrl` to `http://localhost:<port>`
   - Sets `apiKey` to `vertex-proxy` (dummy value, proxy uses GCP ADC)

2. OpenClaw sends requests to `http://localhost:<port>/v1/messages` using the `anthropic` provider
3. The proxy forwards them to Vertex AI using the `@anthropic-ai/vertex-sdk`
4. The model name is passed through from the request (e.g. `claude-sonnet-4-6`)
5. If the primary region returns a 5xx error, the proxy automatically retries with the fallback region

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/messages` | POST | Proxied Anthropic Messages API |
| `/health` | GET | Health check with project, region, active requests, uptime |
| `/` | GET | Basic status check (backwards compatible) |

## Files

- `proxy.js` — Node.js proxy server with region failover, concurrency cap, and graceful shutdown
- `run.sh` — Auto-restart wrapper with crash guard and log rotation
- `vertex-ctl.sh` — Management CLI (installed to `/usr/local/bin/vertex-ctl`)
- `package.json` — Dependencies and metadata

## Reliability Features

- **Region failover** — If the primary region returns 5xx, automatically retries with the fallback region
- **Concurrency cap** — Returns 429 when `VERTEX_MAX_CONCURRENT` is exceeded
- **Crash guard** — `run.sh` stops after 5 rapid crashes within 60 seconds instead of looping forever
- **Log rotation** — Rotates `proxy.log` when it exceeds 10 MB
- **Graceful shutdown** — Drains in-flight requests on SIGTERM/SIGINT before exiting
- **Request validation** — Rejects malformed requests (missing `model` or `messages`) with 400

## Troubleshooting

### `invalid_grant` error in proxy.log
The GCP refresh token has expired. Regenerate:
```bash
# On your local machine:
gcloud auth application-default login --project devex-ai

# Copy the new credentials to the Ocana machine:
# (copy ~/.config/gcloud/application_default_credentials.json to /opt/ocana/openclaw/gcp-adc.json)

# Then restart the proxy (kills old process, starts fresh with new creds):
vertex-ctl start
```
**Note:** ADC refresh tokens can expire. For production, use a GCP service account key instead.

### `Unknown model: anthropic-vertex/...`
The model prefix should be `anthropic/`, not `anthropic-vertex/`. The proxy handles the Vertex translation. Fix:
```bash
openclaw models set "anthropic/claude-sonnet-4-6"
openclaw gateway restart
```

### Proxy fails to start on macOS
The `run.sh` script auto-detects the OS. If `fuser` is unavailable, it falls back to `lsof`. If `nohup` fails with permission errors:
```bash
sudo chown -R $(whoami) /opt/ocana/bifrost
```

### Config validation errors (`models: expected array`)
The `jq` update wiped the models array. Fix:
```bash
openclaw doctor --fix
vertex-ctl start
openclaw gateway restart
```

### `vertex-ctl start` says "GCP credentials not found"
Copy your credentials file:
```bash
cp ~/.config/gcloud/application_default_credentials.json /opt/ocana/openclaw/gcp-adc.json
```

### Proxy crashes in a loop
If the proxy crashes 5 times within 60 seconds, `run.sh` will stop automatically and log:
```
FATAL: 5 crashes in 60s. Stopping. Check proxy.log for errors.
```
Check the log for the root cause before restarting.

### How to verify the proxy works
```bash
vertex-ctl test
```
This sends a real request through the proxy to Vertex AI and shows the response.

## Notes

- Proxy auto-restarts on crash (3s delay via `run.sh`) with crash guard protection
- `vertex-ctl start` kills any existing proxy before starting a new one
- Add a crontab `@reboot` entry to auto-start on machine reboot:
  ```
  @reboot /opt/ocana/bifrost/run.sh >> /opt/ocana/bifrost/proxy.log 2>&1
  ```
- The proxy logs to `/opt/ocana/bifrost/proxy.log` (auto-rotated at 10 MB)
- Set `VERTEX_DEBUG=1` for verbose logging including request sizes and latency
