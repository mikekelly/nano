#!/usr/bin/env python3
"""Local deterministic MCP fixture, no provider or model calls. Both protocol eras."""
import json, os, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
transport, era, directory = sys.argv[1:]
lock = threading.Lock()
subscriptions = set()
listen_id = None
initialized = False
stop = False

def record(value):
    with lock:
        with open(directory + '/wire.jsonl', 'a') as f:
            f.write(json.dumps(value) + '\n')

def notification(method, params, lid=None):
    if era == 'modern' and lid is not None:
        params = dict(params, _meta={'io.modelcontextprotocol/subscriptionId': lid})
    return {'jsonrpc': '2.0', 'method': method, 'params': params}

def reply(req):
    global initialized, listen_id
    method, params = req['method'], req.get('params', {})
    if era == 'modern' and 'id' in req:
        assert params['_meta']['io.modelcontextprotocol/protocolVersion'] == '2026-07-28'
        assert params['_meta']['io.modelcontextprotocol/clientCapabilities'] == {}
    if method == 'server/discover':
        if era == 'legacy': return None, {'code': -32601, 'message': 'Method not found'}
        return {'resultType': 'complete', 'supportedVersions': ['2026-07-28'], 'capabilities': {
            'tools': {'listChanged': True}, 'resources': {'subscribe': True, 'listChanged': True}, 'prompts': {'listChanged': True}}}, None
    if method == 'initialize':
        return {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}, 'resources': {'subscribe': True}, 'prompts': {}}}, None
    if method == 'notifications/initialized': initialized = True; return {}, None
    if method == 'notifications/cancelled':
        if params.get('requestId') == listen_id: listen_id = None
        return {}, None
    if era == 'legacy' and not initialized: return None, {'code': -32000, 'message': 'not initialized'}
    if method == 'subscriptions/listen':
        listen_id = req['id']
        subscriptions.clear()
        subscriptions.update(params['notifications'].get('resourceSubscriptions', []))
        return {}, None
    if method == 'resources/subscribe': subscriptions.add(params['uri']); return {}, None
    if method == 'resources/unsubscribe': subscriptions.discard(params['uri']); return {}, None
    if method == 'tools/list':
        if params.get('cursor') == 'next': return {'tools': [{'name': 'second', 'inputSchema': {'type': 'object'}}]}, None
        tools = [{'name': 'echo', 'description': 'echo arguments', 'inputSchema': {'type': 'object', 'properties': {'region': {'type': 'string', 'x-mcp-header': 'Region'}}}}]
        if transport == 'http' and era == 'modern':
            tools.append({'name': 'invalid', 'inputSchema': {'type': 'object', 'properties': {'n': {'type': 'number', 'x-mcp-header': 'Invalid'}}}})
        return {'tools': tools, 'nextCursor': 'next'}, None
    if method == 'resources/list': return {'resources': [{'uri': 'file://demo', 'name': 'Demo'}]}, None
    if method == 'resources/templates/list': return {'resourceTemplates': [{'uriTemplate': 'file://{name}', 'name': 'Files'}]}, None
    if method == 'prompts/list': return {'prompts': [{'name': 'greeting'}]}, None
    if method == 'prompts/get': return {'messages': [{'role': 'user', 'content': {'type': 'text', 'text': 'Hello'}}]}, None
    if method == 'resources/read':
        return {'contents': [{'uri': params['uri'], 'text': 'x' * 50000 if params['uri'] == 'file://large' else 'hello'}, {'uri': params['uri'], 'blob': 'AAECAw==', 'mimeType': 'application/octet-stream'}]}, None
    if method == 'tools/call':
        if params['name'] == 'die':
            os._exit(17)
        if params['name'] == 'slow': time.sleep(0.5)
        if params['name'] == 'error': return None, {'code': -32602, 'message': 'bad arguments'}
        return {'content': [{'type': 'text', 'text': json.dumps(params.get('arguments', {}))}]}, None
    return None, {'code': -32601, 'message': 'Method not found'}

def response(req, result, error):
    return dict(jsonrpc='2.0', id=req['id'], **({'error': error} if error else {'result': result}))

def stdio_send(msg):
    with lock:
        try:
            sys.stdout.write(json.dumps(msg) + '\n'); sys.stdout.flush()
        except BrokenPipeError: os._exit(0)

def ticker():
    while True:
        time.sleep(0.15)
        if era == 'modern' and listen_id is None: continue
        for uri in list(subscriptions):
            stdio_send(notification('notifications/resources/updated', {'uri': uri}, listen_id))

if transport == 'stdio':
    threading.Thread(target=ticker, daemon=True).start()
    for line in sys.stdin:
        req = json.loads(line); record(req)
        if 'method' not in req: continue
        result, error = reply(req)
        if req['method'] == 'subscriptions/listen':
            stdio_send(notification('notifications/subscriptions/acknowledged', {'notifications': req['params']['notifications']}, req['id']))
        elif 'id' in req:
            if req['method'] == 'tools/call':
                stdio_send(notification('notifications/progress', {'progressToken': 'test', 'progress': 1}))
                stdio_send(notification('notifications/message', {'level': 'info', 'data': 'fixture'}))
                if era == 'legacy':
                    stdio_send({'jsonrpc': '2.0', 'id': 'server-ping', 'method': 'ping'})
                    stdio_send({'jsonrpc': '2.0', 'id': 'server-request', 'method': 'sampling/createMessage', 'params': {}})
            stdio_send(response(req, result, error))
else:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args): pass
        def json_response(self, status, value, session=False):
            data = json.dumps(value).encode() if value is not None else b''
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            if session: self.send_header('Mcp-Session-Id', 'fixture-session')
            self.end_headers(); self.wfile.write(data); self.wfile.flush()
        def sse_start(self):
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close'); self.end_headers()
        def sse(self, msg, event_id=None):
            data = json.dumps(msg, indent=2)
            event = (('id: '+event_id+'\n') if event_id else '') + ''.join('data: ' + x + '\n' for x in data.splitlines()) + '\n'
            # Force frame boundaries across chunks, including inside a UTF-8 body.
            self.wfile.write(event[:13].encode()); self.wfile.flush()
            self.wfile.write(event[13:].encode()); self.wfile.flush()
        def do_GET(self):
            record({'get': True, 'headers': dict(self.headers)})
            if era == 'modern': return self.json_response(405, None)
            assert self.headers.get('Mcp-Session-Id') == 'fixture-session'
            self.sse_start()
            try:
                for i in range(30):
                    time.sleep(.1)
                    for uri in list(subscriptions): self.sse(notification('notifications/resources/updated', {'uri': uri}), str(i))
            except (BrokenPipeError, ConnectionResetError): pass
            self.close_connection = True
        def do_POST(self):
            req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            record({'request': req, 'headers': dict(self.headers)})
            if era == 'legacy' and req['method'] == 'server/discover': return self.json_response(400, {'error': 'legacy'})
            if era == 'modern':
                assert self.headers.get('Mcp-Protocol-Version') == '2026-07-28'
                assert self.headers.get('Mcp-Method') == req['method']
                if req['method'] in ['tools/call', 'resources/read', 'prompts/get']:
                    assert self.headers.get('Mcp-Name') is not None
                if req['method'] == 'tools/call' and req['params'].get('arguments', {}).get('region') is not None:
                    value = req['params']['arguments']['region']
                    actual = self.headers.get('Mcp-Param-Region')
                    if actual and actual.startswith('=?base64?'): actual = __import__('base64').b64decode(actual[9:-2]).decode()
                    assert actual == value, (actual, value)
            elif req['method'] not in ['initialize', 'server/discover']:
                assert self.headers.get('Mcp-Session-Id') == 'fixture-session'
            result, error = reply(req)
            if 'id' not in req: return self.json_response(202, None)
            if req['method'] == 'subscriptions/listen':
                self.sse_start()
                try:
                    self.sse(notification('notifications/subscriptions/acknowledged', {'notifications': req['params']['notifications']}, req['id']))
                    for i in range(30):
                        time.sleep(.1)
                        for uri in list(subscriptions): self.sse(notification('notifications/resources/updated', {'uri': uri}, req['id']))
                except (BrokenPipeError, ConnectionResetError): pass
                self.close_connection = True
            elif req['method'] == 'tools/call':
                self.sse_start()
                self.sse(notification('notifications/progress', {'progressToken': 'test', 'progress': 1}))
                self.sse(notification('notifications/message', {'level': 'info', 'data': 'fixture'}))
                self.sse(response(req, result, error)); self.close_connection = True
            else: self.json_response(200, response(req, result, error), req['method'] == 'initialize')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    with open(directory + '/port', 'w') as f: f.write(str(server.server_port))
    server.serve_forever()
