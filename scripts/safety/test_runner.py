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
        # Explicit v1 provisioning for the synthetic child at its fixture boundary.
        self.intent()

    def intent(self, auth=None, settings=None, invalidated=()):
        entries = {}
        values = [('chatgpt_auth.json', auth)] if auth else []
        values += [('settings/' + key, value) for key, value in (settings or {}).items()]
        for key, value in values:
            v = len(entries) + 1
            entries[key] = dict(state='enabled', version=v, generation=v, value=value)
        for key in invalidated:
            entries[key] = dict(state='invalidated', version=len(entries) + 1)
        atomic(self.root / 'credentials' / 'intent-v1.json', json.dumps(dict(schema_version=1, revision=len(entries), entries=entries)).encode())
        # This synthetic watchdog child is not BEAM; capability fixture is explicit.
        for file, content in [('safety.ex', '@credential_intent_schema 1\ndef credential_intent_lock_schema, do: 1\n@noncredential_settings_schema 1'), ('chatgpt/auth.ex', 'Nano.Safety.credential_write'), ('settings.ex', 'Nano.Safety.credential_read')]:
            path = self.app / 'lib/nano' / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

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
        settings = b'{"KEY":"fake-only"}'
        latest = b'{"access_token":"fake-access","refresh_token":"latest-fake"}'
        atomic(self.state / 'settings.json', settings)
        atomic(self.state / 'chatgpt_auth.json', b'{"access_token":"old","refresh_token":"old"}')
        atomic(self.root / 'credentials' / 'settings.json', settings)
        # Simulates the synchronous write-through hook, not a credential-polling promise.
        atomic(self.root / 'credentials' / 'chatgpt_auth.json', latest)
        atomic(self.state / 'chatgpt_auth.json', latest)
        self.intent(auth=json.loads(latest), settings={'KEY': 'fake-only'})
        self.start(); self.good()
        (self.state / 'settings.json').unlink()
        atomic(self.state / 'chatgpt_auth.json', b'{}')
        wait_for(lambda: (self.state / 'settings.json').exists() and read_json(self.state / 'chatgpt_auth.json') == json.loads(latest))
        self.assertEqual(read_json(self.state / 'settings.json'), json.loads(settings))
        wait_for(lambda: len([n for n in self.notices() if n['kind'] == 'credentials_restored']) == 2)
        for path in (self.root / 'credentials').iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600 if path.is_file() else 0o700)
        evidence = list((self.root / 'evidence').glob('*-chatgpt_auth.json'))
        self.assertEqual(evidence[0].read_bytes(), b'{}')
        self.assertEqual(evidence[0].stat().st_mode & 0o777, 0o600)
        self.assertNotIn('latest-fake', (self.root / 'notices.jsonl').read_text())

    def test_net_snapshot_serializes_refresh_invalidation_and_login_before_kill(self):
        import fcntl
        import threading
        import runner
        from unittest.mock import patch
        for action in ('refresh', 'invalidate', 'login'):
            with self.subTest(action=action):
                old = {'access_token': 'old', 'refresh_token': 'old-refresh'}
                new = {'access_token': 'new', 'refresh_token': 'new-refresh'}
                self.intent(auth=old)
                atomic(self.state / 'chatgpt_auth.json', json.dumps(old).encode())
                net = runner.Net(self.root)
                class Child:
                    def poll(self): return None
                net.child = Child()
                stops = []
                net.stop_child = lambda: stops.append('stop')
                net.notice = lambda *a, **kw: None
                attempted, done = threading.Event(), threading.Event()
                threads = []
                original = runner.read_json
                def writer():
                    fd = os.open(self.root / 'credentials/intent-v1.lock', os.O_RDWR)
                    try:
                        attempted.set()
                        fcntl.flock(fd, fcntl.LOCK_EX)
                        atomic(self.root / 'credentials/intent-blocked-v1.json', b'{}')
                        prior = original(self.root / 'credentials/intent-v1.json')
                        revision = prior['revision'] + 1
                        entry = dict(state='invalidated', version=revision) if action == 'invalidate' else dict(
                            state='enabled', version=revision,
                            generation=prior['entries']['chatgpt_auth.json']['generation'] if action == 'refresh' else revision,
                            value=new)
                        prior['revision'] = revision
                        prior['entries']['chatgpt_auth.json'] = entry
                        atomic(self.root / 'credentials/intent-v1.json', json.dumps(prior).encode())
                        if action == 'invalidate':
                            (self.state / 'chatgpt_auth.json').unlink()
                        else:
                            atomic(self.state / 'chatgpt_auth.json', json.dumps(new).encode())
                        (self.root / 'credentials/intent-blocked-v1.json').unlink()
                    finally:
                        os.close(fd)
                        done.set()
                def interleave(path, default=None):
                    if Path(path) == self.state / 'chatgpt_auth.json' and not threads:
                        thread = threading.Thread(target=writer)
                        threads.append(thread)
                        thread.start()
                        self.assertTrue(attempted.wait(2))
                        self.assertFalse(done.is_set(), 'writer crossed the snapshot lock')
                    return original(path, default)
                with patch.object(runner, 'read_json', interleave):
                    self.assertFalse(net.credentials())
                self.assertTrue(done.wait(2))
                threads[0].join(2)
                self.assertFalse(net.credentials())
                self.assertEqual(stops, [])
                self.assertEqual(original(self.state / 'chatgpt_auth.json', {}), {} if action == 'invalidate' else new)
                # A partial publish holding the OS lock is never considered damage.
                fd = os.open(self.root / 'credentials/intent-v1.lock', os.O_RDWR)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX)
                    self.assertFalse(net.credentials())
                    self.assertEqual(stops, [])
                finally:
                    os.close(fd)

    def test_nonsecret_sidecar_changes_never_become_credential_repair(self):
        from runner import Net
        self.intent(settings={'openrouter_api_key': 'fixture'})
        mixed = b'{"openrouter_api_key":"fixture","eval_timeout_ms":9}'
        atomic(self.state / 'settings.json', mixed)
        net = Net(self.root)
        class Child:
            def poll(self): return None
        net.child = Child()
        stops = []
        net.stop_child = lambda: stops.append('stop')
        for values in ({'eval_timeout_ms': 12345}, {}):
            atomic(self.state / 'settings-noncredentials-v1.json', json.dumps({'schema_version': 1, 'values': values}).encode())
            self.assertFalse(net.credentials())
            self.assertEqual((self.state / 'settings.json').read_bytes(), mixed)
            self.assertEqual(stops, [])

    def test_valid_newer_credentials_are_not_replaced(self):
        self.intent(settings={'NEW': 'valid'})
        atomic(self.state / 'settings.json', b'{"NEW":"valid"}')
        atomic(self.root / 'credentials' / 'settings.json', b'{"OLD":"valid"}')
        self.start(); self.good()
        self.assertEqual((self.state / 'settings.json').read_bytes(), b'{"NEW":"valid"}')
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
        self.intent(settings={'openrouter_api_key': 'fake-old', 'OTHER_KEY': 'fake-new'})
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
        # Offline acknowledgement is not a bypass of a live publisher's lock.
        import fcntl
        (install_root / 'credentials').mkdir(parents=True)
        lock_path = install_root / 'credentials/intent-v1.lock'
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            refused_busy = subprocess.run(command + ['--offline', '--legacy-installation'], capture_output=True)
            self.assertNotEqual(refused_busy.returncode, 0)
            self.assertFalse((install_root / 'credentials/intent-v1.json').exists())
            self.assertFalse((install_root / 'config.json').exists())
            self.assertNotIn(b'fake-latest', refused_busy.stdout + refused_busy.stderr)
        finally:
            os.close(fd)
        inode = lock_path.stat().st_ino
        installed = subprocess.run(command + ['--offline', '--legacy-installation'], capture_output=True)
        self.assertEqual(lock_path.stat().st_ino, inode)
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

    def test_revocation_and_barrier_never_restart_healthy_child_or_restore_old_copy(self):
        from runner import Net, compatible_credentials
        self.intent(invalidated=('chatgpt_auth.json', 'settings/openrouter_api_key'))
        atomic(self.root / 'credentials/chatgpt_auth.json', b'{"access_token":"revoked","refresh_token":"revoked"}')
        atomic(self.root / 'credentials/settings.json', b'{"openrouter_api_key":"revoked"}')
        self.start(); self.good(); pid = self.status()['child_pid']
        time.sleep(.3)
        self.assertEqual(self.status()['child_pid'], pid)
        self.assertFalse((self.state / 'chatgpt_auth.json').exists())
        self.assertNotIn('openrouter_api_key', read_json(self.state / 'settings.json', {}))
        atomic(self.root / 'credentials/intent-blocked-v1.json', b'{}')
        atomic(self.state / 'chatgpt_auth.json', b'{"access_token":"stale","refresh_token":"stale"}')
        self.assertFalse(Net(self.root).credentials())
        self.assertFalse(compatible_credentials(self.base, self.root))
        self.assertTrue(compatible_credentials(self.app, self.root))
        self.assertEqual(self.status()['child_pid'], pid)

    def test_actual_fallback_and_disabled_boot_refuse_pre_intent_source(self):
        # Inject a retained legacy known-good evidence candidate at this fixture
        # boundary. The actual Net fallback path must refuse to execute it.
        self.start(); good = self.good(); self.stop()
        from runner import bounded_digest
        (Path(good['source']) / 'lib/nano/safety.ex').write_text('legacy source')
        good['digest'] = bounded_digest(Path(good['source']))
        atomic(self.root / 'good.json', json.dumps(good).encode())
        self.intent(invalidated=('chatgpt_auth.json',))
        atomic(self.root / 'budget.json', b'{"attempts":0}')
        (self.app / 'node.py').write_text('this cannot compile (')
        self.start(); self.proc.wait(timeout=15)
        self.assertEqual(self.status()['state'], 'maintenance_blocked')
        self.assertTrue(any(n['kind'] == 'incompatible_credential_authority' for n in self.notices()))
        self.assertEqual(len(list((self.root / 'evidence').glob('*-boot.log'))), 2,
                         'incompatible fallback must never be launched')
        # Loss of every protected file is not new-installation permission for
        # disabled direct-exec (nor for fallback source unaware of missing intent).
        for name in ('intent-v1.json', 'intent-blocked-v1.json', 'intent-required-v1'):
            (self.root / 'credentials' / name).unlink(missing_ok=True)
        self.assertFalse((self.root / 'credentials/intent-v1.json').exists())
        (self.root / 'disabled').touch()
        (self.app / 'lib/nano/safety.ex').write_text('legacy source')
        self.start(); self.proc.wait(timeout=5)
        self.assertEqual(self.status()['state'], 'maintenance_blocked')
        self.assertEqual(len(list((self.root / 'evidence').glob('*-boot.log'))), 2)

    def test_settings_aliases_cannot_bypass_invalidation(self):
        from runner import Net
        self.intent(settings={'OTHER_KEY': 'enabled'}, invalidated=('settings/openrouter_api_key',))
        atomic(self.state / 'settings.json', b'{"OPENROUTER_API_KEY":"revoked","other_key":"stale","eval_timeout_ms":777}')
        self.assertTrue(Net(self.root).credentials())
        self.assertEqual(read_json(self.state / 'settings.json'), {'OTHER_KEY': 'enabled', 'eval_timeout_ms': 777})

    def test_missing_and_corrupt_authority_never_enables_legacy_backup(self):
        from runner import Net
        atomic(self.root / 'credentials/chatgpt_auth.json', b'{"access_token":"old","refresh_token":"old"}')
        self.assertFalse(Net(self.root).credentials())
        atomic(self.root / 'credentials/intent-v1.json', b'{broken')
        self.assertFalse(Net(self.root).credentials())
        self.assertFalse((self.state / 'chatgpt_auth.json').exists())

    def test_single_owner(self):
        self.start(); self.good()
        other = subprocess.run([sys.executable, str(RUNNER)], env={**os.environ, 'NANO_SAFETY_DIR': str(self.root)}, capture_output=True, timeout=3)
        self.assertEqual(other.returncode, 0)
        self.assertIn(b'already owns', other.stderr)


if __name__ == '__main__': unittest.main()
