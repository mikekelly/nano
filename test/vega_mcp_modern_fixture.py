"""Strict 2026-07-28 reference-wire fixture: no init, sessions or GET streams."""
import sys, os, json, threading, queue, base64, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
VERSION = "2026-07-28"
streams = {}
hanging = 0
lock = threading.Lock()
outlock = threading.Lock()

def out(msg):
    with outlock:
        print(json.dumps(msg), flush=True)

def notification(method, sid, params):
    return {"jsonrpc": "2.0", "method": method, "params": dict(params, _meta={"io.modelcontextprotocol/subscriptionId": sid})}

def decode(value):
    if value.startswith("=?base64?") and value.endswith("?="):
        return base64.b64decode(value[9:-2]).decode()
    return value

def tool(name, schema=None):
    return {"name": name, "inputSchema": schema or {"type": "object"}}

def handle(msg, sink, headers=None):
    method = msg.get("method")
    p = msg.get("params", {})
    if headers is not None:
        assert method != "notifications/cancelled", 'Modern HTTP cancellation closes stream, never POSTs notification'
    if method == "notifications/cancelled":
        with lock:
            streams.pop(p["requestId"], None)
        return None
    assert method not in ("initialize", "notifications/initialized", "resources/subscribe", "resources/unsubscribe")
    ident = msg["id"]
    meta = p["_meta"]
    assert meta["io.modelcontextprotocol/clientCapabilities"] == {}
    assert meta["io.modelcontextprotocol/clientInfo"]["name"] == "vega"
    if meta["io.modelcontextprotocol/protocolVersion"] != VERSION:
        return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32022, "message": "Unsupported protocol version", "data": {"supported": [VERSION]}}}
    if headers is not None:
        assert headers["Mcp-Protocol-Version"] == VERSION
        assert headers["Mcp-Method"] == method
        assert "Mcp-Session-Id" not in headers
        assert "Last-Event-ID" not in headers
        if method in ("tools/call", "prompts/get", "resources/read"):
            assert decode(headers["Mcp-Name"]) == p.get("name", p.get("uri"))
        if method == "tools/call" and p["name"] == "echo" and "route" in p.get("arguments", {}):
            assert decode(headers["Mcp-Param-Region"]) == p["arguments"]["route"]["region"]
    result = {"resultType": "complete", "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "modern-wire", "version": "1"}}}
    if method == "server/discover":
        result.update(supportedVersions=[VERSION], capabilities={"tools": {"listChanged": True}, "resources": {"subscribe": True, "listChanged": True}, "prompts": {"listChanged": True}})
    elif method == "tools/list":
        schema = {"type": "object", "properties": {"route": {"type": "object", "properties": {"region": {"type": "string", "x-mcp-header": "Region"}}}}}
        bad = {"type": "object", "properties": {"x": {"type": "string", "x-mcp-header": "Bad\r\n"}}}
        misplaced = {"type": "object", "properties": {"a": {"type": "array", "items": {"type": "string", "x-mcp-header": "Item"}}}}
        if p.get("cursor") == "more":
            result.update(tools=[tool("paged")])
        else:
            result.update(tools=[tool("echo", schema), tool("emit"), tool("active"), tool("stale"), tool("die"), tool("hang"), tool("close"), tool("invalid", bad), tool("misplaced", misplaced)], nextCursor="more")
    elif method == "resources/list":
        result.update(resources=[{"uri": "test://value", "name": "value"}])
    elif method == "resources/templates/list":
        result.update(resourceTemplates=[{"uriTemplate": "test://{name}", "name": "template"}])
    elif method == "resources/read":
        result.update(contents=[{"uri": p["uri"], "text": "modern value"}])
    elif method == "prompts/list":
        result.update(prompts=[{"name": "greet"}])
    elif method == "prompts/get":
        result.update(messages=[{"role": "user", "content": {"type": "text", "text": "hello modern"}}])
    elif method == "subscriptions/listen":
        requested = p["notifications"]
        allowed = dict(requested)
        allowed["resourceSubscriptions"] = [uri for uri in requested.get("resourceSubscriptions", []) if uri != "test://unsupported"]
        with lock:
            streams[ident] = (allowed, sink)
        if "test://early" in allowed["resourceSubscriptions"]:
            sink(notification("notifications/resources/updated", ident, {"uri": "test://early"}))
        sink(notification("notifications/subscriptions/acknowledged", ident, {"notifications": allowed}))
        return None
    elif method == "tools/call":
        name = p["name"]
        if name == "die":
            os._exit(17)
        if name == "hang":
            return None
        if name == "emit" or name == "stale" or name == "close":
            with lock:
                listeners = list(streams.items())
            for sid, (filt, deliver) in listeners:
                if name == "close":
                    deliver({"jsonrpc": "2.0", "id": sid, "result": {"resultType": "complete", "_meta": {"io.modelcontextprotocol/subscriptionId": sid}}})
                    continue
                for uri in filt.get("resourceSubscriptions", []):
                    deliver(notification("notifications/resources/updated", sid + (999 if name == "stale" else 0), {"uri": uri}))
                if filt.get("toolsListChanged"):
                    deliver(notification("notifications/tools/list_changed", sid, {}))
            sink({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "modern", "progress": 1}})
            result.update(content=[{"type": "text", "text": "emitted"}])
        elif name == "active":
            with lock:
                count = len(streams) + hanging
            result.update(content=[{"type": "text", "text": str(count)}])
        else:
            result.update(content=[{"type": "text", "text": json.dumps(p.get("arguments", {}))}])
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
    def chunk(self, msg):
        data = ("data: " + json.dumps(msg) + "\n\n").encode()
        self.wfile.write(("%x\r\n" % len(data)).encode()+data+b"\r\n"); self.wfile.flush()
    def do_GET(self):
        raise AssertionError("Modern clients must not open GET stream")
    def do_POST(self):
        global hanging
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        incoming = queue.Queue()
        result = handle(msg, incoming.put, self.headers)
        if msg["method"] == "subscriptions/listen":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                while True:
                    try:
                        item = incoming.get(timeout=.05)
                        self.chunk(item)
                        if "id" in item:
                            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush(); return
                    except queue.Empty:
                        # Frequent keepalives detect closed client stream quickly.
                        data = b":keepalive\n\n"
                        self.wfile.write(("%x\r\n" % len(data)).encode()+data+b"\r\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with lock:
                    streams.pop(msg["id"], None)
        elif msg["method"] == "tools/call" and msg["params"]["name"] == "hang":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            with lock:
                hanging += 1
            try:
                while True:
                    data = b":waiting\n\n"
                    self.wfile.write(("%x\r\n" % len(data)).encode()+data+b"\r\n"); self.wfile.flush()
                    time.sleep(.02)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with lock:
                    hanging -= 1
        elif result is None:
            self.send_response(202)

            self.send_header("Content-Length", "0")
            self.end_headers()
        elif msg["method"] == "tools/call":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while not incoming.empty():
                self.chunk(incoming.get())
            self.chunk(result)
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        else:
            data = json.dumps(result).encode()
            self.send_response(404 if "error" in result else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

if len(sys.argv)>1 and sys.argv[1]=="http":
    threading.Thread(target=lambda: (sys.stdin.buffer.read(), os._exit(0)), daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
else:
    for line in sys.stdin:
        result = handle(json.loads(line), out)
        if result is not None:
            out(result)
