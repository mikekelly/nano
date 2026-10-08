#!/usr/bin/env python3
"""Deterministic, dependency-free MCP demonstration server (not a reference SDK).
Both 2026-07-28 and legacy MCP. No network, filesystem, shell or model access.
"""
import json
import os
import sys

legacy_only = "--legacy" in sys.argv
value = "initial"
subscriptions = {}
legacy_uris = set()
fail_subscribe = False
fail_unsubscribe = False


def emit(message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)


def notify(method, params):
    emit(dict(method=method, params=params))


def result(request, data):
    if "id" not in request:
        return
    if not legacy_only and request.get("method") != "initialize":
        data = dict(resultType="complete", **data)
    emit(dict(id=request["id"], result=data))


def error(request, code, message):
    emit(dict(id=request["id"], error=dict(code=code, message=message)))


def updates():
    if "demo://value" in legacy_uris:
        notify("notifications/resources/updated", dict(uri="demo://value"))
    for sub_id, filters in subscriptions.items():
        if "demo://value" in filters.get("resourceSubscriptions", []):
            notify("notifications/resources/updated", dict(uri="demo://value", _meta={"io.modelcontextprotocol/subscriptionId": sub_id}))


caps = dict(tools=dict(listChanged=True), resources=dict(subscribe=True, listChanged=True), prompts=dict(listChanged=True))
for line in sys.stdin:
    try:
        r = json.loads(line)
        m = r.get("method", "")
        p = r.get("params", {})
        if m == "server/discover":
            if legacy_only:
                error(r, -32602, "Initialize first")
            else:
                result(r, dict(supportedVersions=["2026-07-28"], capabilities=caps, _meta={"io.modelcontextprotocol/serverInfo": dict(name="nano-demo", version="1.0.0")}))
        elif m == "initialize":
            result(r, dict(protocolVersion=p["protocolVersion"], capabilities=caps, serverInfo=dict(name="nano-demo", version="1.0.0")))
        elif m == "notifications/cancelled":
            subscriptions.pop(p.get("requestId"), None)
        elif m.startswith("notifications/"):
            pass
        elif m == "subscriptions/listen":
            subscriptions[r["id"]] = p["notifications"]
            notify("notifications/subscriptions/acknowledged", dict(notifications=p["notifications"], _meta={"io.modelcontextprotocol/subscriptionId": r["id"]}))
        elif m == "resources/subscribe":
            if p["uri"].startswith("hang://"):
                continue
            if fail_subscribe:
                fail_subscribe = False
                error(r, -32602, "Demo transient rejection")
            else:
                legacy_uris.add(p["uri"])
                result(r, {})
        elif m == "resources/unsubscribe":
            if fail_unsubscribe:
                fail_unsubscribe = False
                error(r, -32602, "Demo transient rejection")
            else:
                legacy_uris.discard(p["uri"])
                result(r, {})
        elif m == "test/fail_subscriptions":
            fail_subscribe = True
            fail_unsubscribe = True
            result(r, {})
        elif m == "tools/list":
            names = ["echo", "set_value", "large", "crash", "hang"] if "cursor" not in p else ["second_page"]
            tools = [dict(name=n, description="Demo tool: " + n, inputSchema=dict(type="object", properties={}, additionalProperties=True)) for n in names]
            result(r, dict(tools=tools, **({"nextCursor": "page2"} if "cursor" not in p else {}), ttlMs=0, cacheScope="private"))
        elif m == "resources/list":
            result(r, dict(resources=[dict(uri="demo://value", name="Mutable demo value", mimeType="text/plain")], ttlMs=0, cacheScope="private"))
        elif m == "resources/templates/list":
            result(r, dict(resourceTemplates=[], ttlMs=0, cacheScope="private"))
        elif m == "prompts/list":
            result(r, dict(prompts=[dict(name="greeting", arguments=[dict(name="name", required=False)])], ttlMs=0, cacheScope="private"))
        elif m == "prompts/get":
            result(r, dict(messages=[dict(role="user", content=dict(type="text", text="Hello " + p.get("arguments", {}).get("name", "world")))]))
        elif m == "resources/read":
            result(r, dict(contents=[dict(uri=p["uri"], mimeType="text/plain", text=value)], ttlMs=0, cacheScope="private"))
        elif m == "tools/call":
            name = p["name"]
            args = p.get("arguments", {})
            if name == "crash":
                os._exit(3)
            if name == "hang":
                continue
            if name == "set_value":
                value = args["value"]
                updates()
            text = "x" * args.get("size", 50000) if name == "large" else args.get("text", value)
            result(r, dict(content=[dict(type="text", text=text)]))
        elif m == "test/close_subscriptions":
            for sub_id in list(subscriptions):
                emit(dict(id=sub_id, result=dict(resultType="complete", _meta={"io.modelcontextprotocol/subscriptionId": sub_id})))
            subscriptions.clear()
            result(r, {})
        elif m == "test/metadata":

            result(r, dict(metadata=p.get("_meta")))
        elif m == "test/input":
            emit(dict(id=r["id"], result=dict(resultType="input_required", inputRequests=[], text=p.get("text", ""))))
        elif m == "test/notifications":
            notify("notifications/progress", dict(progressToken="test", progress=1, total=2))
            notify("notifications/message", dict(level="info", data="demo log"))
            result(r, {})
        else:
            error(r, -32601, "Method not found")
    except Exception as exc:
        print(str(exc), file=sys.stderr, flush=True)
