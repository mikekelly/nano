import sys, json, os, time
mode, trace = sys.argv[1:3]
subscriptions = []
stream = None

def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)

def event(method, params={}):
    if mode == "modern" and stream is not None:
        params = dict(params, _meta={"io.modelcontextprotocol/subscriptionId": stream})
    send(dict(method=method, params=params))

caps = {"tools": {"listChanged": True}, "resources": {"subscribe": True, "listChanged": True}, "prompts": {"listChanged": True}}
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    p = msg.get("params", {})
    id = msg.get("id")
    with open(trace, "a") as f:
        f.write(json.dumps(msg) + "\n")
    result = {}
    if method == "server/discover":
        if mode == "broken":
            send(dict(id=id, result={"supportedVersions": 42, "capabilities": []}))
            continue
        if mode == "legacy":
            send(dict(id=id, error={"code": -32601, "message": "Unknown method"}))
            continue
        assert p["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
        result = {"supportedVersions": ["2026-07-28"], "capabilities": caps}
    elif method == "initialize":
        assert mode == "legacy"
        result = {"protocolVersion": "2025-11-25", "capabilities": caps, "serverInfo": {"name": "fixture", "version": "1"}}
    elif method == "subscriptions/listen":
        stream = id
        subscriptions = p["notifications"]["resourceSubscriptions"]
        if "hang://resource" in subscriptions:
            continue
        if "close://resource" in subscriptions:
            send(dict(id=id, result={"resultType": "complete"}))
            continue
        if "slow://resource" in subscriptions:
            time.sleep(0.2)
        if "reject://resource" in subscriptions:
            event("notifications/subscriptions/acknowledged", {"notifications": {}})
            continue
        event("notifications/subscriptions/acknowledged", {"notifications": p["notifications"]})
        continue
    elif method == "notifications/cancelled":
        if p["requestId"] == stream:
            stream = None
        continue
    elif method == "tools/list":
        result = {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}], "nextCursor": "second"} if not p.get("cursor") else {"tools": [{"name": "update"}]}
    elif method == "resources/list":
        result = {"resources": [{"uri": "test://resource", "name": "fixture"}]}
    elif method == "resources/templates/list":
        result = {"resourceTemplates": [{"uriTemplate": "test://{id}", "name": "template"}]}
    elif method == "prompts/list":
        result = {"prompts": [{"name": "hello"}]}
    elif method == "resources/read":
        result = {"contents": [{"uri": p["uri"], "text": "resource"}]}
    elif method == "prompts/get":
        result = {"messages": [{"role": "user", "content": {"type": "text", "text": "hello"}}]}
    elif method == "resources/subscribe":
        subscriptions.append(p["uri"])
    elif method == "resources/unsubscribe":
        subscriptions.remove(p["uri"])
    elif method == "tools/call":
        name = p["name"]
        if name == "hang":
            continue
        if name == "die":
            sys.exit(1)
        if name == "error":
            send(dict(id=id, error={"code": -32099, "message": "E" * 20000}))
            continue
        if name == "malformed":
            send(dict(method="notifications/resources/updated", params=[]))
            send(dict(method="notifications/resources/updated", params={"_meta": False}))
            send(dict(method="notifications/subscriptions/acknowledged", params={"_meta": False}))
        if name == "update":
            for uri in subscriptions:
                event("notifications/resources/updated", {"uri": uri})
            event("notifications/tools/list_changed")
        text = "😀" * 20000 if name == "large" else json.dumps(p.get("arguments", {}))
        result = {"content": [{"type": "text", "text": text}]}
    elif not id:
        continue
    send(dict(id=id, result=result))
