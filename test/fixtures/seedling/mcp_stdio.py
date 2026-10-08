import sys, json, os, signal, time
mode = sys.argv[1]
initialized = False
subscriptions = {}
legacy_subs = set()

def emit(obj):
    print(json.dumps(dict(jsonrpc="2.0", **obj)), flush=True)
def response(req, result):
    if mode != "legacy": result = dict(resultType="complete", **result)
    emit(dict(id=req['id'], result=result))
def notify(method, params):
    emit(dict(method=method, params=params))
def changes():
    if mode == "legacy":
        for uri in legacy_subs: notify("notifications/resources/updated", dict(uri=uri))
        notify("notifications/tools/list_changed", {})
    else:
        for sid, filt in subscriptions.items():
            meta = {"io.modelcontextprotocol/subscriptionId": sid}
            for uri in filt.get("resourceSubscriptions", []):
                notify("notifications/resources/updated", dict(uri=uri, _meta=meta))
            if filt.get("toolsListChanged"): notify("notifications/tools/list_changed", dict(_meta=meta))

for line in sys.stdin:
    req = json.loads(line)
    method, params = req['method'], req.get('params', {})
    if method == "notifications/cancelled":
        subscriptions.pop(params['requestId'], None)
        continue
    if method == "notifications/initialized":
        initialized = True
        continue
    if 'id' not in req: continue
    if mode == "legacy" and method != "initialize" and not initialized:
        emit(dict(id=req['id'], error=dict(code=-32602, message="Initialize first")))
        continue
    if mode != "legacy":
        meta = params.get('_meta', {})
        assert meta['io.modelcontextprotocol/protocolVersion'] == "2026-07-28"
        assert meta['io.modelcontextprotocol/clientCapabilities'] == {}
    caps = dict(tools=dict(listChanged=True), resources=dict(subscribe=True,listChanged=True), prompts=dict(listChanged=True), logging={})
    if method == "server/discover":
        response(req, dict(supportedVersions=["2026-07-28"], capabilities=caps))
    elif method == "initialize":
        response(req, dict(protocolVersion="2025-11-25", capabilities=caps, serverInfo=dict(name="script",version="1")))
    elif method == "subscriptions/listen":
        subscriptions[req['id']] = params['notifications']
        notify("notifications/subscriptions/acknowledged", dict(_meta={"io.modelcontextprotocol/subscriptionId":req['id']}, notifications=params['notifications']))
    elif method == "resources/subscribe":
        legacy_subs.add(params['uri']); response(req,{})
    elif method == "resources/unsubscribe":
        legacy_subs.discard(params['uri']); response(req,{})
    elif method == "tools/list":
        if params.get('cursor'):
            response(req,dict(tools=[dict(name="next",inputSchema=dict(type="object"))]))
        else:
            response(req,dict(tools=[dict(name=n,inputSchema=dict(type="object")) for n in ["echo","big","changes","exit","hang"]],nextCursor="page2"))
    elif method == "tools/call":
        name = params['name']
        if name == "fork":
            child = os.fork()
            if child == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                time.sleep(120)
                os._exit(0)
            response(req, dict(childPid=child))
            continue
        if name == "exit": os._exit(3)

        if name == "hang": continue
        if name == "bad_notification": notify("notifications/message",42); continue
        if name == "malformed": print("not json",flush=True); continue

        if name == "oversize": print("X"*100000,flush=True); continue
        if name == "changes": changes()
        token = params.get('_meta',{}).get('progressToken')
        if token: notify("notifications/progress",dict(progressToken=token,progress=1,total=1))
        if params.get('_meta',{}).get('io.modelcontextprotocol/logLevel') or mode == "legacy":
            notify("notifications/message",dict(level="info",data="hello"))
        response(req,dict(content=[dict(type="text",text="λ"*10000 if name == "big" else json.dumps(params.get('arguments',{})))],isError=False))
    elif method == "resources/list": response(req,dict(resources=[dict(uri="test://one",name="one")]))
    elif method == "resources/templates/list": response(req,dict(resourceTemplates=[dict(uriTemplate="test://{name}",name="any")]))
    elif method == "resources/read": response(req,dict(contents=[dict(uri=params['uri'],text="resource body"),dict(uri="test://binary",blob="AAEC",mimeType="application/octet-stream")]))
    elif method == "prompts/list": response(req,dict(prompts=[dict(name="hello",arguments=[dict(name="who",required=True)])]))
    elif method == "prompts/get": response(req,dict(messages=[dict(role="user",content=dict(type="text",text="Hello " + params['arguments']['who']))]))
    elif method == "test/stale":
        notify("notifications/resources/updated",dict(uri="test://one",_meta={"io.modelcontextprotocol/subscriptionId":-1}));response(req,{})
    else: emit(dict(id=req['id'],error=dict(code=-32601,message="Unknown method")))
