#!/bin/sh
set -eu
# Prerequisite on Debian: apt-get install python3-venv
python3 -m venv /data/seedling/mcp-fetch
/data/seedling/mcp-fetch/bin/pip install 'mcp-server-fetch==2026.8.18'
