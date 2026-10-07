# Configured filesystem server on this node

`/app/priv/vega_mcp.json` includes `vega-filesystem`, backed by the **actual official** `@modelcontextprotocol/server-filesystem@2026.8.31`, installed under `/data/vega-mcp-tools/node_modules` and run with `/usr/bin/node`. Package files survive an agent/node restart; an entirely new image needs explicit installation via `sh /app/scripts/vega/install-mcp-filesystem.sh` (installs Debian Node/npm if absent, then the pinned package). The installer is a reproduction recipe, not part of boot or a silent network action. The current node was installed from the sibling's already-tested official package tree; installer itself has not been executed here.

```elixir
Vega.MCP.connect("vega-filesystem")
Vega.MCP.tools("vega-filesystem")
Vega.MCP.call_tool("vega-filesystem", "read_text_file", %{"path" => "/app/NOTES.md", "head" => 4})
```

Parent actually ran these from eval: negotiated2025-11-25, discovered15 tools and read NOTES head correctly. It allows `/app` and `/data/vega`; it can modify them, so only trusted agents should use it. It offers tools, not resources or subscriptions; those are exercised by protocol integration servers in the MCP suite. Legacy sample `filesystem` uses npx and remains optional when npm/npx exist. Modern2026 support is a separate followup, not claimed by this server.
