#!/bin/sh
set -eu
# Explicit opt-in installation; no dependency installation happens during MCP connect.
# Run as root on this Debian node if npm/node are absent.
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  apt-get update
  apt-get install -y nodejs npm
fi
mkdir -p /data/vega-mcp-tools
cd /data/vega-mcp-tools
npm install --no-audit --no-fund --save-exact @modelcontextprotocol/server-filesystem@2026.8.31
printf '%s
' 'Installed pinned MCP filesystem server. Use Vega.MCP.connect("vega-filesystem").'
