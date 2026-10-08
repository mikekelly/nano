#!/usr/bin/env python3
"""Valid discovery, then deliberately ignores stdin EOF and SIGTERM."""
import json, os, signal, sys, time
marker = sys.argv[1]
signal.signal(signal.SIGTERM, lambda *_: open(marker, 'w').write('ignored-term'))
request = json.loads(sys.stdin.readline())
print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': {
    'supportedVersions': ['2026-07-28'], 'capabilities': {}}}), flush=True)
time.sleep(60)
