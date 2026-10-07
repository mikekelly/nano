#!/bin/sh
set -eu
# Explicit opt-in reproduction for an older image; fresh seedling Docker images include this.
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  apt-get update
  apt-get install -y nodejs npm
fi
mkdir -p /opt/vega-mcp-tools
cp /app/priv/vega_mcp_runtime/package*.json /opt/vega-mcp-tools/
cd /opt/vega-mcp-tools
npm ci --omit=dev --no-audit --no-fund
printf '%s
' 'Installed locked MCP filesystem server. Use Vega.MCP.connect("vega-filesystem").'
