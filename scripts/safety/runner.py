#!/usr/bin/env python3
"""Independent watchdog. Installed copy and all state live outside /app.
Never prints credential values or subprocess output. See README.md.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.request
import uuid


def atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_bytes())
    except (OSError, ValueError):
        return default


def valid_credentials(path):
    data = read_json(path)
    if not isinstance(data, dict) or not data:
        return False
    if Path(path).name == 'chatgpt_auth.json':
        return bool(data.get('refresh_token') and data.get('access_token'))
    return True


def credential_repair(current, backup):
    if not valid_credentials(backup):
        return None
    if not valid_credentials(current):
        return Path(backup).read_bytes()
    if Path(current).name == 'settings.json':
        new = read_json(current)
        old = read_json(backup)
        repaired = dict(new)
        for key, value in old.items():
            # Seed provider key and opaque operator-owned settings are secrets.
            secret = key == 'openrouter_api_key' or (isinstance(key, str) and key.upper() == key)
            if secret and isinstance(value, str) and value and not new.get(key):
                repaired[key] = value
        if repaired != new:
            return json.dumps(repaired).encode()
    return None


class Net:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.config = read_json(self.root / 'config.json')
        if not isinstance(self.config, dict):
            raise ValueError('missing safety config')
        self.app = Path(self.config['app']).resolve()
        self.state_dir = Path(self.config['state_dir']).resolve()
        self.deps = Path(self.config.get('deps_path') or os.environ.get('MIX_DEPS_PATH') or self.app / 'deps').resolve()
        if self.root == self.app or self.root.is_relative_to(self.app):
            raise ValueError('safety root must be outside checkout')
        for name, default in [('interval', 5), ('probe_timeout', 2), ('lockup_timeout', 60), ('boot_timeout', 120), ('backoff', 10), ('stable_seconds', 300), ('max_attempts', 3)]:
            value = self.config.get(name, default)
            if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
                raise ValueError('invalid positive bound')
        if not isinstance(self.config.get('command'), list) or not self.config['command']:
            raise ValueError('command must be nonempty argv')
        self.child = None
        self.stopping = False
        self.status = {}
        self.budget = read_json(self.root / 'budget.json', {'attempts': 0})
        self.good = read_json(self.root / 'good.json')

    def save(self, name, value):
        atomic(self.root / name, json.dumps(value).encode())

    def notice(self, kind, **fields):
        event = dict(at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), kind=kind, **fields)
        # Structured fields are controlled metadata, never exception bodies or credentials.
        fd = os.open(self.root / 'notices.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, 'a') as out:
            out.write(json.dumps(event) + '\n')
            out.flush()
            os.fsync(out.fileno())
        print('Nano safety: ' + json.dumps(event), file=sys.stderr, flush=True)
        self.status['last_notice'] = event

    def update(self, state, **fields):
        self.status.update(state=state, updated=int(time.time()), watchdog_pid=os.getpid(), **fields)
        self.save('status.json', self.status)

    def snapshot(self):
        destination = self.root / 'revisions' / uuid.uuid4().hex
        # Copy before boot: a later edit cannot falsely become the revision that served.
        subprocess.run([sys.executable, __file__, '--snapshot', str(self.app), str(destination), str(self.deps)],
                       timeout=self.config.get('snapshot_timeout', 120), check=True)
        revision = subprocess.run(['git', '-C', str(self.app), 'rev-parse', 'HEAD'],
                                  capture_output=True, text=True, timeout=5).stdout.strip()
        metadata = {'source': str(destination), 'revision': revision, 'captured': int(time.time()), 'digest': bounded_digest(destination)}
        self.save('candidate.json', metadata)
        return metadata

    def credentials(self):
        restored = False
        for name in ('settings.json', 'chatgpt_auth.json'):
            current = self.state_dir / name
            backup = self.root / 'credentials' / name
            # No polling backup writes: they could regress a single-use refresh token.
            if credential_repair(current, backup) is not None:
                # Stop publishers before rechecking/restoring. An ordinary in-process
                # refresh can no longer race restoration of the latest copy.
                if self.child and self.child.poll() is None:
                    self.stop_child()
                    restored = True
                repair = credential_repair(current, backup)
                if repair is None:
                    continue
                evidence = self.root / 'evidence' / (uuid.uuid4().hex + '-' + name)
                if current.exists():
                    atomic(evidence, current.read_bytes())
                atomic(current, repair)
                self.notice('credentials_restored', file=name, evidence=str(evidence) if evidence.exists() else None)
                restored = True
        return restored

    def stop_child(self):
        if self.child and self.child.poll() is None:
            # Include the compiler and any descendants; a stopped scheduler ignores TERM.
            try:
                os.killpg(self.child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.child.wait(timeout=10)

    def signal_stop(self, *_):
        self.stopping = True
        self.stop_child()

    def probe(self):
        try:
            timeout = self.config.get('probe_timeout', 2)
            reply = subprocess.run([sys.executable, __file__, '--probe', self.config['health_url'], str(timeout)],
                                   capture_output=True, timeout=timeout, check=True)
            data = json.loads(reply.stdout)
            if data.get('responsive') and str(data.get('boot')) == str(self.child.pid):
                return data
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        return None

    def launch(self, source, deps):
        env = os.environ.copy()
        env.update(self.config.get('env', {}))
        env['NANO_SAFETY_DIR'] = str(self.root)
        env['STATE_DIR'] = str(self.state_dir)
        env['MIX_BUILD_ROOT'] = str(self.root / 'build')
        env['MIX_DEPS_PATH'] = str(deps)
        log = self.root / 'evidence' / (uuid.uuid4().hex + '-boot.log')
        log.parent.mkdir(exist_ok=True, mode=0o700)
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as out:
            self.child = subprocess.Popen(self.config['command'], cwd=source, env=env,
                                          stdout=out, stderr=out, start_new_session=True)
        self.update('booting', child_pid=self.child.pid, source=str(source), boot_log=str(log))
        return log

    def run(self):
        signal.signal(signal.SIGTERM, self.signal_stop)
        signal.signal(signal.SIGINT, self.signal_stop)
        if (self.root / 'disabled').exists():
            self.update('disabled')
            self.notice('disabled', action='unprotected direct boot')
            os.chdir(self.app)
            env = {**os.environ, **self.config.get('env', {}), 'NANO_SAFETY_DIR': str(self.root), 'STATE_DIR': str(self.state_dir), 'MIX_BUILD_ROOT': str(self.root / 'build')}
            os.execvpe(self.config['command'][0], self.config['command'], env)
        if self.budget['attempts'] >= self.config.get('max_attempts', 3):
            self.update('exhausted', attempts=self.budget['attempts'])
            self.notice('recovery_exhausted', action='manual reset required; no further boot attempts')
            return 0  # Docker on-failure will not loop; persistent brake also covers always.
        self.credentials()
        try:
            candidate = self.snapshot()
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            self.notice('candidate_capture_failed', error_type=type(exc).__name__, preserved_checkout=str(self.app))
            if not self.good:
                self.budget['attempts'] = self.config.get('max_attempts', 3)
                self.save('budget.json', self.budget)
                self.update('exhausted', attempts=self.budget['attempts'])
                self.notice('recovery_exhausted', action='checkout cannot be captured and no known-good exists; manual repair required')
                return 0
            candidate = None
        # A persistent fallback is used after failures even across container restarts.
        active = self.good if (self.budget['attempts'] or candidate is None) and self.good else candidate
        use_primary = self.budget['attempts'] == 0 and candidate is not None
        while not self.stopping:
            if self.budget['attempts'] >= self.config.get('max_attempts', 3):
                self.update('exhausted', attempts=self.budget['attempts'])
                self.notice('recovery_exhausted', evidence=str(self.root / 'evidence'), action='manual reset required')
                return 0
            self.budget['attempts'] += 1
            self.save('budget.json', self.budget)
            # Never execute a known-good evidence snapshot. Normal boot keeps /app
            # as cwd; fallback runs a fresh writable copy, leaving evidence intact.
            source = self.app
            if not use_primary:
                source = self.root / 'runtime' / uuid.uuid4().hex
                subprocess.run([sys.executable, __file__, '--snapshot', active['source'], str(source)],
                               timeout=self.config.get('snapshot_timeout', 120), check=True)
            deps = source / 'deps'
            if use_primary:
                deps = self.root / 'runtime-deps' / uuid.uuid4().hex
                if (Path(active['source']) / 'deps').exists():
                    subprocess.run([sys.executable, __file__, '--snapshot', str(Path(active['source']) / 'deps'), str(deps)],
                                   timeout=self.config.get('snapshot_timeout', 120), check=True)
            log = self.launch(source, deps)
            self.update('booting', evidence_source=active['source'], fallback=not use_primary)
            started = last_response = time.monotonic()
            promoted = False
            responded = False
            healthy_since = None
            budget_reset = False
            promotion_deferred = False
            while not self.stopping:
                now = time.monotonic()
                if self.child.poll() is not None:
                    reason = 'boot_or_runtime_exit'
                    break
                if (self.root / 'disabled').exists():
                    self.update('disabled', child_pid=self.child.pid)
                    # Keep child alive but cease watchdog actions; operators can re-enable
                    # on next start. Status remains visibly disabled while waiting.
                    while self.child.poll() is None and not self.stopping:
                        self.update('disabled')
                        time.sleep(self.config.get('interval', 5))
                    return 0
                if self.credentials():
                    reason = 'credentials_reload_restart'
                    break
                health = self.probe()
                if health:
                    responded = True
                    healthy_since = healthy_since or now
                    last_response = now
                    self.update('watching', attempts=self.budget['attempts'], known_good=self.good)
                    attested = False
                    if health.get('model_served') and not promoted:
                        try:
                            attested = bounded_digest(source) == active['digest']
                        except (OSError, ValueError, subprocess.SubprocessError):
                            pass  # Source churn cannot justify killing a responsive node.
                        if not attested and not promotion_deferred:
                            self.notice('promotion_deferred', action='source changed or cannot be attested; healthy node kept running')
                            promotion_deferred = True
                    if attested:
                        self.good = active
                        self.save('good.json', active)
                        self.notice('known_good', revision=active['revision'], source=active['source'])
                        promoted = True
                else:
                    healthy_since = None
                timeout = self.config.get('lockup_timeout', 60) if responded else self.config.get('boot_timeout', 120)
                if now - last_response > timeout:
                    reason = 'lockup' if responded else 'boot_timeout'
                    break
                # Reset recovery budget only after sustained health, not one lucky probe.
                if promoted and healthy_since and not budget_reset and now - healthy_since > self.config.get('stable_seconds', 300):
                    budget_reset = True
                    self.budget = {'attempts': 0}
                    self.save('budget.json', self.budget)
                time.sleep(self.config.get('interval', 5))
            self.stop_child()
            if self.stopping:
                self.update('stopped')
                return 0
            self.notice(reason, evidence=str(log), preserved_checkout=str(self.app), action='restart known-good' if self.good else 'retry captured source')
            self.update('recovering')
            active = self.good or candidate
            use_primary = False
            time.sleep(self.config.get('backoff', 10))
        return 0


def main():
    os.umask(0o077)
    root = Path(os.environ.get('NANO_SAFETY_DIR', '/data/safety'))
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    lock = open(root / 'watchdog.lock', 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Nano safety: another watchdog already owns this root', file=sys.stderr)
        return 0
    net = None
    try:
        net = Net(root)
        return net.run()
    except Exception as exc:
        # Always leave a minimal stderr notice even if the evidence volume is full.
        print('Nano safety: watchdog_error ' + type(exc).__name__ + '; monitoring stopped', file=sys.stderr, flush=True)
        if net:
            net.stop_child()
            try:
                net.notice('watchdog_error', error_type=type(exc).__name__, action='stopped; inspect private evidence')
                net.update('error')
            except Exception:
                pass
        else:
            print('Nano safety: invalid config; refusing an unprotected boot', file=sys.stderr)
        return 0


def bounded_digest(source):
    reply = subprocess.run([sys.executable, __file__, '--digest', str(source)],
                           capture_output=True, timeout=10, check=True)
    return reply.stdout.decode().strip()


def source_digest(source):
    digest = hashlib.sha256()
    source = Path(source)
    # Source/config/prompts only; dependency trees are captured but not hashed per probe.
    for directory, dirs, files in os.walk(source):
        dirs[:] = sorted(d for d in dirs if d not in ('.git', '_build', 'deps', 'tmp', '__pycache__'))
        for name in sorted(files):
            path = Path(directory) / name
            if name == '.git':
                continue
            if not stat.S_ISREG(path.stat().st_mode):
                raise ValueError('nonregular source file')
            digest.update(str(path.relative_to(source)).encode())
            with path.open('rb') as content:
                for chunk in iter(lambda: content.read(65536), b''):
                    digest.update(chunk)
    return digest.hexdigest()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--probe':
        try:
            with urllib.request.urlopen(sys.argv[2], timeout=float(sys.argv[3])) as response:
                sys.stdout.buffer.write(response.read(4096))
        except Exception:
            sys.exit(1)
    elif len(sys.argv) > 1 and sys.argv[1] == '--digest':
        print(source_digest(sys.argv[2]))
    elif len(sys.argv) > 1 and sys.argv[1] == '--snapshot':
        ignored = ['.git', '_build', 'tmp', '__pycache__']
        if len(sys.argv) > 4:
            ignored.append('deps')
        shutil.copytree(sys.argv[2], sys.argv[3], ignore=shutil.ignore_patterns(*ignored))
        if len(sys.argv) > 4 and Path(sys.argv[4]).is_dir():
            shutil.copytree(sys.argv[4], Path(sys.argv[3]) / 'deps',
                            ignore=shutil.ignore_patterns('_build', '__pycache__'))
    else:
        sys.exit(main())
