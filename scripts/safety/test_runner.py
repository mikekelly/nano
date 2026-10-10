import json
import os
from pathlib import Path
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from runner import atomic, read_json

RUNNER = Path(__file__).with_name('runner.py').resolve()
FIXTURE = r"""
import http.server, json, os
from pathlib import Path
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps(dict(responsive=True, boot=str(os.getpid()), model_served=not Path('no_model').exists())).encode())
    def log_message(self, *args): pass
http.server.HTTPServer(('127.0.0.1', int(os.environ['PORT'])), Handler).serve_forever()
"""


def wait_for(fn, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('condition timed out')


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='altair-safety-')
        self.base = Path(self.temp.name)
        self.app = self.base / 'app'; self.app.mkdir()
        (self.app / 'node.py').write_text(FIXTURE)
        self.root = self.base / 'safety'; self.root.mkdir(mode=0o700)
        self.state = self.base / 'state'; self.state.mkdir()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        self.config = dict(app=str(self.app), deps_path=str(self.app / 'deps'), state_dir=str(self.state), health_url=f'http://127.0.0.1:{port}/api/safety/health',
                           command=[sys.executable, 'node.py'], env={'PORT': str(port)}, interval=.05,
                           probe_timeout=.1, lockup_timeout=.3, boot_timeout=1, backoff=.1,
                           max_attempts=3, stable_seconds=100)
        self.save_config()
        self.proc = None

    def save_config(self):
        atomic(self.root / 'config.json', json.dumps(self.config).encode())

    def start(self):
        self.proc = subprocess.Popen([sys.executable, str(RUNNER)], env={**os.environ, 'NANO_SAFETY_DIR': str(self.root)},
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def status(self):
        return read_json(self.root / 'status.json', {})

    def notices(self):
        path = self.root / 'notices.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def good(self):
        return wait_for(lambda: read_json(self.root / 'good.json'))

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate(); self.proc.wait(timeout=10)

    def tearDown(self):
        self.stop()
        self.temp.cleanup()

    def test_lockup_kills_process_group_and_restarts(self):
        self.start(); good = self.good(); old = self.status()['child_pid']
        os.kill(old, signal.SIGSTOP)
        wait_for(lambda: any(n['kind'] == 'lockup' for n in self.notices()))
        wait_for(lambda: self.status().get('state') == 'watching' and self.status().get('child_pid') != old)
        with self.assertRaises(ProcessLookupError): os.kill(old, 0)
        self.assertEqual(read_json(self.root / 'good.json')['source'], good['source'])

    def test_bad_boot_fallback_preserves_dirty_checkout(self):
        self.start(); good = self.good(); self.stop()
        atomic(self.root / 'budget.json', b'{"attempts":0}')
        broken = 'this is invalid python (\n'
        (self.app / 'node.py').write_text(broken)
        (self.app / 'untracked-work').write_text('do not lose me')
        self.start()
        wait_for(lambda: any(n['kind'] == 'boot_or_runtime_exit' for n in self.notices()))
        wait_for(lambda: self.status().get('state') == 'watching')
        self.assertEqual(self.status()['evidence_source'], good['source'])
        self.assertNotEqual(self.status()['source'], good['source'])
        self.assertEqual((self.app / 'node.py').read_text(), broken)
        candidate = read_json(self.root / 'candidate.json')
        self.assertEqual((Path(candidate['source']) / 'untracked-work').read_text(), 'do not lose me')
        self.assertTrue(list((self.root / 'evidence').glob('*-boot.log')))

    def test_deleted_empty_and_rotated_credentials(self):
        settings = b'{"key":"fake-only"}'
        latest = b'{"access_token":"fake-access","refresh_token":"latest-fake"}'
        atomic(self.state / 'settings.json', settings)
        atomic(self.state / 'chatgpt_auth.json', b'{"access_token":"old","refresh_token":"old"}')
        atomic(self.root / 'credentials' / 'settings.json', settings)
        # Simulates the synchronous write-through hook, not a credential-polling promise.
        atomic(self.root / 'credentials' / 'chatgpt_auth.json', latest)
        atomic(self.state / 'chatgpt_auth.json', latest)
        self.start(); self.good()
        (self.state / 'settings.json').unlink()
        atomic(self.state / 'chatgpt_auth.json', b'{}')
        wait_for(lambda: (self.state / 'settings.json').exists() and (self.state / 'chatgpt_auth.json').read_bytes() == latest)
        self.assertEqual((self.state / 'settings.json').read_bytes(), settings)
        wait_for(lambda: len([n for n in self.notices() if n['kind'] == 'credentials_restored']) == 2)
        for path in (self.root / 'credentials').iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        evidence = list((self.root / 'evidence').glob('*-chatgpt_auth.json'))
        self.assertEqual(evidence[0].read_bytes(), b'{}')
        self.assertEqual(evidence[0].stat().st_mode & 0o777, 0o600)
        self.assertNotIn('latest-fake', (self.root / 'notices.jsonl').read_text())

    def test_valid_newer_credentials_are_not_replaced(self):
        atomic(self.state / 'settings.json', b'{"new":"valid"}')
        atomic(self.root / 'credentials' / 'settings.json', b'{"old":"valid"}')
        self.start(); self.good()
        self.assertEqual((self.state / 'settings.json').read_bytes(), b'{"new":"valid"}')
        self.assertFalse(any(n['kind'] == 'credentials_restored' for n in self.notices()))

    def test_brake_persists_across_runner_restarts(self):
        (self.app / 'node.py').write_text('raise RuntimeError("broken")')
        self.start(); self.proc.wait(timeout=15)
        self.assertEqual(self.status()['state'], 'exhausted')
        self.assertEqual(read_json(self.root / 'budget.json')['attempts'], 3)
        self.start(); self.proc.wait(timeout=5)
        self.assertEqual(read_json(self.root / 'budget.json')['attempts'], 3)
        self.assertEqual(len(list((self.root / 'evidence').glob('*-boot.log'))), 3)

    def test_http_without_model_success_is_not_promoted(self):
        (self.app / 'no_model').touch()
        self.start()
        wait_for(lambda: self.status().get('state') == 'watching')
        self.assertFalse((self.root / 'good.json').exists())

    def test_disabled_never_kills_child(self):
        self.start(); self.good(); pid = self.status()['child_pid']
        (self.root / 'disabled').touch()
        wait_for(lambda: self.status().get('state') == 'disabled')
        os.kill(pid, signal.SIGSTOP); time.sleep(.6)
        os.kill(pid, 0)
        self.assertEqual(self.status()['state'], 'disabled')

    def test_source_edits_cannot_falsely_promote_or_mutate_good(self):
        (self.app / 'no_model').touch()
        self.start()
        wait_for(lambda: self.status().get('state') == 'watching')
        # Source changed after capture, even if runtime reports a model success.
        (self.app / 'no_model').unlink()
        (self.app / 'later_work').write_text('new source')
        time.sleep(.4)
        self.assertFalse((self.root / 'good.json').exists())

    def test_budget_only_resets_after_contiguous_health(self):
        self.config['stable_seconds'] = .8
        self.config['lockup_timeout'] = .6
        self.save_config()
        self.start(); self.good()
        pid = self.status()['child_pid']
        time.sleep(.3)
        os.kill(pid, signal.SIGSTOP); time.sleep(.3); os.kill(pid, signal.SIGCONT)
        time.sleep(.4)
        self.assertEqual(read_json(self.root / 'budget.json')['attempts'], 1)
        wait_for(lambda: read_json(self.root / 'budget.json')['attempts'] == 0, 5)

    def test_lost_secret_merge_preserves_newer_valid_settings(self):
        atomic(self.state / 'settings.json', b'{"openrouter_api_key":"fake-old","node_max_tokens_per_hour":1}')
        atomic(self.root / 'credentials' / 'settings.json', (self.state / 'settings.json').read_bytes())
        self.start(); self.good()
        atomic(self.state / 'settings.json', b'{"node_max_tokens_per_hour":999,"OTHER_KEY":"fake-new"}')
        wait_for(lambda: read_json(self.state / 'settings.json').get('openrouter_api_key') == 'fake-old')
        self.assertEqual(read_json(self.state / 'settings.json')['node_max_tokens_per_hour'], 999)
        self.assertEqual(read_json(self.state / 'settings.json')['OTHER_KEY'], 'fake-new')

    def test_bad_snapshot_still_reaches_intact_known_good(self):
        self.start(); good = self.good(); self.stop()
        atomic(self.root / 'budget.json', b'{"attempts":0}')
        os.mkfifo(self.app / 'hostile-fifo')
        self.start()
        wait_for(lambda: self.status().get('state') == 'watching')
        self.assertEqual(self.status()['evidence_source'], good['source'])
        self.assertTrue(any(n['kind'] == 'candidate_capture_failed' for n in self.notices()))

    def test_fallback_runtime_edits_never_mutate_known_good(self):
        self.start(); good = self.good(); old = self.status()['child_pid']
        os.kill(old, signal.SIGSTOP)
        wait_for(lambda: self.status().get('state') == 'watching' and self.status().get('child_pid') != old)
        runtime = Path(self.status()['source'])
        (runtime / 'later-work').write_text('only runtime')
        self.assertFalse((Path(good['source']) / 'later-work').exists())

    def test_trickling_http_cannot_defeat_total_probe_deadline(self):
        (self.app / 'node.py').write_text(FIXTURE.replace("self.wfile.write(json.dumps(dict(responsive=True, boot=str(os.getpid()), model_served=not Path('no_model').exists())).encode())", "\n        import time\n        try:\n            for _ in range(200):\n                self.wfile.write(b' '); self.wfile.flush(); time.sleep(.03)\n        except BrokenPipeError: pass"))
        self.start(); self.proc.wait(timeout=10)
        self.assertEqual(self.status()['state'], 'exhausted')

    def test_uncapturable_checkout_without_good_is_persistently_braked(self):
        os.mkfifo(self.app / 'hostile-fifo')
        self.start(); self.proc.wait(timeout=10)
        self.assertEqual(self.status()['state'], 'exhausted')
        self.assertEqual(read_json(self.root / 'budget.json')['attempts'], 3)
        self.start(); self.proc.wait(timeout=5)
        self.assertEqual(self.status()['state'], 'exhausted')

    def test_installer_requires_offline_and_does_not_start_watchdog(self):
        (self.app / 'mix.exs').write_text('# disposable placeholder')
        atomic(self.state / 'chatgpt_auth.json', b'{"access_token":"fake","refresh_token":"fake-latest"}')
        install_root = self.base / 'installed-safety'
        installer = RUNNER.with_name('install.py')
        command = [sys.executable, str(installer), '--app', str(self.app), '--root', str(install_root), '--state-dir', str(self.state)]
        refused = subprocess.run(command, capture_output=True)
        self.assertNotEqual(refused.returncode, 0)
        self.assertFalse((install_root / 'config.json').exists())
        installed = subprocess.run(command + ['--offline'], capture_output=True)
        self.assertEqual(installed.returncode, 0)
        self.assertFalse((install_root / 'status.json').exists())
        self.assertEqual(read_json(install_root / 'credentials' / 'chatgpt_auth.json')['refresh_token'], 'fake-latest')
        self.assertEqual(install_root.stat().st_mode & 0o777, 0o700)
        self.assertEqual((install_root / 'credentials' / 'chatgpt_auth.json').stat().st_mode & 0o777, 0o600)
        self.assertNotIn(b'fake-latest', installed.stdout + installed.stderr)

    def test_promotion_digest_failure_never_kills_healthy_child(self):
        (self.app / 'no_model').touch()
        self.start(); wait_for(lambda: self.status().get('state') == 'watching')
        pid = self.status()['child_pid']
        os.mkfifo(self.app / 'source-fifo')
        (self.app / 'no_model').unlink()
        wait_for(lambda: any(n['kind'] == 'promotion_deferred' for n in self.notices()))
        time.sleep(.4)
        self.assertEqual(self.status()['child_pid'], pid)
        os.kill(pid, 0)
        self.assertEqual(self.status()['state'], 'watching')
        self.assertFalse((self.root / 'good.json').exists())

    def test_external_dependency_capture_survives_original_loss(self):
        external = self.base / 'image-deps'; external.mkdir()
        (external / 'fixture_dep.py').write_text('VALUE = "captured"')
        self.config['deps_path'] = str(external); self.save_config()
        (self.app / 'node.py').write_text('import os, sys\nsys.path.insert(0, os.environ["MIX_DEPS_PATH"])\nimport fixture_dep\nassert fixture_dep.VALUE == "captured"\n' + FIXTURE)
        self.start(); good = self.good(); self.stop()
        self.assertEqual((Path(good['source']) / 'deps' / 'fixture_dep.py').read_text(), 'VALUE = "captured"')
        self.assertFalse((Path(good['source']) / 'deps' / '__pycache__').exists())
        shutil.rmtree(external)
        atomic(self.root / 'budget.json', b'{"attempts":0}')
        self.start()
        wait_for(lambda: self.status().get('state') == 'watching')
        self.assertTrue(self.status()['fallback'])
        self.assertEqual(self.status()['evidence_source'], good['source'])

    def test_single_owner(self):
        self.start(); self.good()
        other = subprocess.run([sys.executable, str(RUNNER)], env={**os.environ, 'NANO_SAFETY_DIR': str(self.root)}, capture_output=True, timeout=3)
        self.assertEqual(other.returncode, 0)
        self.assertIn(b'already owns', other.stderr)


if __name__ == '__main__': unittest.main()
