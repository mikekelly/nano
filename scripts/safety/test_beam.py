"""Opt-in destructive real-node test, never uses /app or /data as targets.
Run NANO_SAFETY_BEAM_TEST=1 python3 -m unittest discover -s scripts/safety -p test_beam.py -v
All provider responses and credentials are explicitly synthetic local fixtures.
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from runner import atomic, read_json
from test_runner import wait_for

SOURCE = Path(__file__).resolve().parents[2]


class Provider(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(dict(data=[dict(id='fixture/model', context_length=100000, reasoning=dict(supported_efforts=[]))])).encode())
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/oauth/token':
            self.server.rotations += 1
            data = dict(access_token='fake-access-' + str(self.server.rotations),
                        refresh_token='fake-refresh-' + str(self.server.rotations), expires_in=3600)
        else:
            data = dict(choices=[dict(message=dict(role='assistant', content='fixture reply'), finish_reason='stop')], usage={})
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    def log_message(self, *args): pass


@unittest.skipUnless(os.environ.get('NANO_SAFETY_BEAM_TEST') == '1', 'opt-in real BEAM disposable copy')
class RealBeamRecovery(unittest.TestCase):
    def test_real_node_lockup_compile_failure_and_refresh_restore(self):
        with tempfile.TemporaryDirectory(prefix='altair-safety-beam-') as temp:
            base = Path(temp); app = base / 'app'; root = base / 'safety'; state = base / 'state'
            root.mkdir(mode=0o700); state.mkdir()
            shutil.copytree(SOURCE, app, ignore=shutil.ignore_patterns('.git', '_build', 'tmp', '__pycache__'))
            self.assertTrue((app / 'deps' / 'phoenix').is_dir(), 'copy dependencies into assigned worktree first')
            provider = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
            provider.rotations = 0
            thread = threading.Thread(target=provider.serve_forever, daemon=True); thread.start()
            provider_url = f'http://127.0.0.1:{provider.server_port}'
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            settings = dict(openrouter_api_key='fake-test-key', openrouter_base_url=provider_url, chatgpt_auth_url=provider_url)
            tokens = dict(access_token='fake-access-initial', refresh_token='fake-refresh-initial', account_id='fake-account', expires_at=int(time.time()) + 3600)
            for name, data in [('settings.json', settings), ('chatgpt_auth.json', tokens)]:
                atomic(state / name, json.dumps(data).encode())
                atomic(root / 'credentials' / name, json.dumps(data).encode())
            config = dict(app=str(app), state_dir=str(state), health_url=f'http://127.0.0.1:{port}/api/safety/health',
                          command=['elixir', '-S', 'mix', 'run', '--no-halt'],
                          env=dict(MIX_ENV='dev', ERL_FLAGS='+S 2:2', PORT=str(port), LISTEN_IP='127.0.0.1',
                                   LOG_DIR=str(base / 'logs'), SPILL_DIR=str(base / 'spill'), ERL_CRASH_DUMP=str(base / 'crash.dump')),
                          interval=.2, probe_timeout=.3, lockup_timeout=1, boot_timeout=90,
                          backoff=.3, max_attempts=20, stable_seconds=1000)
            atomic(root / 'config.json', json.dumps(config).encode())
            runner = Path(__file__).with_name('runner.py')
            proc = None
            def start():
                return subprocess.Popen([sys.executable, str(runner)], env={**os.environ, 'NANO_SAFETY_DIR': str(root)},
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            def status(): return read_json(root / 'status.json', {})
            def ready(): return wait_for(lambda: status().get('state') == 'watching', 100)
            def evaluate(code):
                req = urllib.request.Request(f'http://127.0.0.1:{port}/api/eval', data=json.dumps(dict(code=code)).encode(), headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=10) as reply: return json.load(reply)
            try:
                proc = start(); ready()
                self.assertFalse((root / 'good.json').exists(), 'HTTP alone must not qualify')
                result = evaluate('case NanoAgent.start(name: "safety-fixture", model: "fixture/model", reasoning: "off", max_turns: 0, max_tokens: 0, max_context: 100000, system_prompt: "Disposable safety test; reply briefly.") do {:ok, _} -> NanoAgent.notify("safety-fixture", :fixture); :ok; _ -> :error end')
                self.assertEqual(result['result'], ':ok')
                wait_for(lambda: read_json(root / 'good.json'), 10)
                good = read_json(root / 'good.json')
                # Exercise actual auth refresh persistence hook against a fake OAuth server.
                result = evaluate('Nano.ChatGPT.Auth.refresh("fake-access-initial"); :ok')
                self.assertEqual(result['result'], ':ok')
                latest = read_json(root / 'credentials' / 'chatgpt_auth.json')
                self.assertEqual(latest['refresh_token'], 'fake-refresh-1')
                self.assertEqual(read_json(state / 'chatgpt_auth.json'), latest)
                # Exercise actual settings persistence hook, no polling copy.
                evaluate('Nano.Settings.put("fixture_key", "fake-latest"); :ok')
                self.assertEqual(read_json(root / 'credentials' / 'settings.json')['FIXTURE_KEY'], 'fake-latest')
                old = status()['child_pid']; os.kill(old, signal.SIGSTOP)
                wait_for(lambda: status().get('child_pid') != old and status().get('state') == 'watching', 100)
                with self.assertRaises(ProcessLookupError): os.kill(old, 0)
                self.assertEqual(evaluate('NanoAgent.info("safety-fixture") != nil')['result'], 'true')
                # Empty auth and delete settings. Independent watcher restores and reloads.
                (state / 'settings.json').unlink(); atomic(state / 'chatgpt_auth.json', b'{}')
                previous = status()['child_pid']
                wait_for(lambda: read_json(state / 'chatgpt_auth.json') == latest, 10)
                wait_for(lambda: status().get('child_pid') != previous and status().get('state') == 'watching', 100)
                self.assertEqual(read_json(state / 'settings.json')['FIXTURE_KEY'], 'fake-latest')
                # Real compile failure on edited checkout; last served snapshot still boots.
                proc.terminate(); proc.wait(timeout=15)
                atomic(root / 'budget.json', b'{"attempts":0}')
                broken = 'defmodule Broken do\nthis cannot compile (\n'
                (app / 'lib' / 'broken.ex').write_text(broken)
                proc = start(); ready()
                self.assertEqual(status()['evidence_source'], good['source'])
                self.assertNotEqual(status()['source'], good['source'])
                self.assertEqual(evaluate('NanoAgent.info("safety-fixture") != nil')['result'], 'true')
                self.assertEqual((app / 'lib' / 'broken.ex').read_text(), broken)
                candidate = read_json(root / 'candidate.json')
                self.assertEqual((Path(candidate['source']) / 'lib' / 'broken.ex').read_text(), broken)
                notices = (root / 'notices.jsonl').read_text()
                for kind in ['lockup', 'credentials_restored', 'boot_or_runtime_exit']:
                    self.assertIn(kind, notices)
                self.assertNotIn('fake-refresh-1', notices)
                for path in (root / 'credentials').iterdir():
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                print('Real BEAM copy: model-gated promotion, SIGSTOP kill/restart, actual OAuth refresh write-through, deleted/empty credential restore/reload, real compile-error fallback and preserved source passed.')
            finally:
                if proc and proc.poll() is None:
                    proc.terminate(); proc.wait(timeout=15)
                provider.shutdown(); provider.server_close()
