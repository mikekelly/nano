#!/usr/bin/env python3
"""A tiny MCP server over stdio, for tests: one tool (echo), one resource (test://doc),
one prompt (greet), and a resource update pushed shortly after resources/subscribe."""
import json, sys, threading, time

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def handle(msg):
    method = msg.get("method")
    mid = msg.get("id")
    if mid is None:
        return
    if method == "initialize":
        result = {
            "protocolVersion": "2025-06-18",
            "capabilities": {
                "tools": {"listChanged": True},
                "resources": {"subscribe": True, "listChanged": True},
                "prompts": {},
            },
            "serverInfo": {"name": "fake", "version": "0.1.0"},
        }
    elif method == "tools/list":
        result = {"tools": [{"name": "echo", "description": "echo text",
                             "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}},
                                             "required": ["text"]}}]}
    elif method == "tools/call":
        if msg["params"]["name"] != "echo":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
            return
        text = msg["params"]["arguments"].get("text", "")
        result = {"content": [{"type": "text", "text": "echo: " + text}]}
    elif method == "resources/list":
        result = {"resources": [{"uri": "test://doc", "name": "doc", "mimeType": "text/plain"}]}
    elif method == "resources/read":
        result = {"contents": [{"uri": msg["params"]["uri"], "mimeType": "text/plain", "text": "hello from fake"}]}
    elif method == "resources/subscribe":
        uri = msg["params"]["uri"]
        result = {}
        threading.Thread(target=lambda: (time.sleep(0.2), send({
            "jsonrpc": "2.0", "method": "notifications/resources/updated", "params": {"uri": uri}}))).start()
    elif method == "prompts/list":
        result = {"prompts": [{"name": "greet", "description": "greeting", "arguments": []}]}
    elif method == "prompts/get":
        result = {"description": "greeting", "messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}]}
    elif method == "ping":
        result = {}
    else:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
        return
    send({"jsonrpc": "2.0", "id": mid, "result": result})

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        handle(json.loads(line))
    except Exception as e:
        sys.stderr.write(str(e) + "\n")
