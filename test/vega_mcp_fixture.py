"""Real OS subprocess / HTTP fixture for MCP legacy wire integration tests."""
import sys, json, os, threading, queue
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

subscriptions = set()
events = queue.Queue()
initialized = False

def handle(msg):
    global initialized
    method = msg.get("method")
    p = msg.get("params", {})
    if method == "notifications/initialized":
        initialized = True
        return None
    if "id" not in msg:
        return None
    ident = msg["id"]
    result = {}
    if method == "initialize":
        result = {"protocolVersion": os.getenv("VEGA_MCP_PROTOCOL", "2025-11-25"), "capabilities": {"tools": {"listChanged": True}, "resources": {"subscribe": True}, "prompts": {}}, "serverInfo": {"name": "local-fixture", "version": "1"}}
    elif not initialized:
        return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": "not initialized"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}], "nextCursor": "second"} if not p.get("cursor") else {"tools": []}
    elif method == "resources/list":
        result = {"resources": [{"uri": "test://value", "name": "value"}]}
    elif method == "resources/templates/list":
        result = {"resourceTemplates": [{"uriTemplate": "test://{name}", "name": "template"}]}
    elif method == "prompts/list":
        result = {"prompts": [{"name": "greet"}]}
    elif method == "prompts/get":
        result = {"messages": [{"role": "user", "content": {"type": "text", "text": "hello " + p.get("arguments", {}).get("name", "world")}}]}
    elif method == "resources/read":
        result = {"contents": [{"uri": p["uri"], "text": "value"}]}
    elif method == "resources/subscribe":
        subscriptions.add(p["uri"])
    elif method == "resources/unsubscribe":
        subscriptions.discard(p["uri"])
    elif method == "tools/call":
        name = p["name"]
        if name == "credential_log":
            events.put({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "error", "data": "bad bearer " + os.getenv("VEGA_MCP_FAKE_SECRET", "missing")}})
        if name == "credential_error":

            return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": "bad bearer " + os.getenv("VEGA_MCP_FAKE_SECRET", "missing")}}
        if name == "die":

            os._exit(17)
        if name == "hang":
            return None
        if name == "media_image":
            image = {"type": "image", "mimeType": "image/png", "data": p["arguments"]["data"]}
            events.put({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": image}})
            result = {"content": [{"type": "text", "text": "caption stays intact", "annotations": {"audience": ["assistant"]}}, image]}
        elif name == "large":

            result = {"content": [{"type": "text", "text": "x" * 100000}]}
        elif name == "emit":
            for uri in list(subscriptions):
                events.put({"jsonrpc": "2.0", "method": "notifications/resources/updated", "params": {"uri": uri}})
            events.put({"jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": {}})
            events.put({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "test", "progress": 1}})
            result = {"content": [{"type": "text", "text": "emitted"}]}
        else:
            result = {"content": [{"type": "text", "text": json.dumps(p.get("arguments", {}))}]}
    else:
        return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "unknown method"}}
    return {"jsonrpc": "2.0", "id": ident, "result": result}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when a client cancels a request-scoped SSE stream.
    def log_message(self, *args):
        pass
    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert "application/json" in self.headers["Accept"]
        assert "text/event-stream" in self.headers["Accept"]
        if msg.get("method") != "initialize":
            assert self.headers.get("Mcp-Session-Id") == "fixture-session"
        if msg.get("method") == "tools/call" and msg.get("params", {}).get("name") == "expire":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        result = handle(msg)
        if result is None:

            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif msg.get("method") == "tools/call":
            data = ("event: message\r\ndata: " + json.dumps(result) + "\r\n\r\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            # force arbitrary chunk boundaries and CRLF splitting
            for i in range(0, len(data), 7):
                self.wfile.write(data[i:i+7]); self.wfile.flush()
        else:
            data = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Mcp-Session-Id", "fixture-session")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
    def do_GET(self):
        assert self.headers["Mcp-Session-Id"] == "fixture-session"
        if self.path == "/nostream":
            self.send_response(405)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/resume":
            if self.headers.get("Last-Event-ID") == "fixture-event":
                data = b'id: fixture-event\nretry: 20\ndata: {"jsonrpc":"2.0","method":"notifications/message","params":{"data":"resumed"}}\n\n'
            else:
                data = b'id: fixture-event\nretry: 20\ndata:\n\n'
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data); self.wfile.flush()
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                try:
                    data = ("data: " + json.dumps(events.get(timeout=1)) + "\n\n").encode()
                except queue.Empty:
                    data = b": keepalive\n\n"
                self.wfile.write(("%x\r\n" % len(data)).encode()+data+b"\r\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

if len(sys.argv) > 1 and sys.argv[1] == "http":
    # Port closure closes stdin: HTTP servers otherwise linger without reading it.
    threading.Thread(target=lambda: (sys.stdin.buffer.read(), os._exit(0)), daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
else:
    for line in sys.stdin:
        result = handle(json.loads(line))
        if result is not None:
            print(json.dumps(result), flush=True)
        while not events.empty():
            print(json.dumps(events.get()), flush=True)
