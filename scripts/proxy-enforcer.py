#!/usr/bin/env python3
"""
Proxy Config Enforcer for OpenClaw

Ensures the OpenClaw bedrock and anthropic providers always point to the
local vertex-proxy (localhost:4100) instead of the default cloud backend.

Run via cron every 2 minutes to survive gateway restarts that reset the config:
  */2 * * * * python3 /opt/ocana/bifrost/proxy-enforcer.py 2>/dev/null

The gateway pulls config from the Ocana cloud on restart, overwriting local
changes. This script silently re-applies the proxy routing when needed.
"""

import json
import sys
import os

PORT = os.environ.get("PROXY_PORT", "4100")
PROXY_URL = f"http://localhost:{PORT}"
API_KEY = "vertex-proxy"

FILES = [
    "/opt/ocana/openclaw/openclaw.json",
    "/opt/ocana/openclaw/agents/main/agent/models.json",
]

PROVIDERS_TO_UPDATE = ["bedrock", "anthropic"]

changed_any = False

for filepath in FILES:
    if not os.path.isfile(filepath):
        continue
    try:
        with open(filepath) as f:
            data = json.load(f)

        # openclaw.json nests under .models.providers, models.json under .providers
        providers = data.get("models", data).get("providers", data.get("providers", {}))

        changed = False
        for provider in PROVIDERS_TO_UPDATE:
            if provider in providers and providers[provider].get("baseUrl") != PROXY_URL:
                providers[provider]["baseUrl"] = PROXY_URL
                providers[provider]["apiKey"] = API_KEY
                changed = True

        if changed:
            with open(filepath, "w") as f:
                json.dump(data, f, indent=2)
            changed_any = True

    except Exception:
        pass

if changed_any and "--verbose" in sys.argv:
    print(f"Config enforced: providers → {PROXY_URL}")
