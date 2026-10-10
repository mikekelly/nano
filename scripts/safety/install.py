#!/usr/bin/env python3
"""Explicit installer: never starts a process, never changes bin/start or /app."""
import argparse
import json
import os
from pathlib import Path
import shutil
from runner import atomic, read_json, valid_credentials, canonical_settings, canonical_setting, credential_lock, NONSECRET_SETTINGS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true', help='Required acknowledgement: credential writers are stopped for maintenance')
    kind = parser.add_mutually_exclusive_group(required=True)
    kind.add_argument('--new-installation', action='store_true', help='Attest this installation never held protected authority')
    kind.add_argument('--legacy-installation', action='store_true', help='Attest offline migration of an installation that never used intent v1')
    parser.add_argument('--root', default='/data/safety')
    parser.add_argument('--app', default='/app')
    parser.add_argument('--state-dir', default='/data/state')
    parser.add_argument('--port', type=int, default=4000)
    args = parser.parse_args()
    if not args.offline:
        parser.error('quiesce all credential writers first, then pass --offline; concurrent bootstrap is unsafe')
    os.umask(0o077)
    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    try:
        with credential_lock(root):
            install(parser, args, root)
    except OSError:
        parser.error('credential lock or persistence unavailable; quiesce writers and reconcile offline')


def install(parser, args, root):
    if (root / 'config.json').exists():
        parser.error('already installed; review existing config rather than replacing it')
    app = Path(args.app).resolve()
    if root == app or root.is_relative_to(app):
        parser.error('safety root must be outside app checkout')
    if not (app / 'mix.exs').is_file():
        parser.error('app must contain mix.exs')
    if not shutil.which('python3') or not shutil.which('elixir') or not shutil.which('flock'):
        parser.error('python3, elixir and util-linux flock are required at every container start')
    config = {
        'app': str(app), 'deps_path': str(Path(os.environ.get('MIX_DEPS_PATH') or app / 'deps').resolve()), 'state_dir': str(Path(args.state_dir).resolve()),
        'health_url': 'http://127.0.0.1:%d/api/safety/health' % args.port,
        'command': ['sh', '-c', 'exec elixir --name nano@127.0.0.1 --cookie "${NODE_COOKIE:-$(cat /opt/nano/cookie)}" -S mix run --no-halt'],
        'env': {'MIX_ENV': 'prod', 'PORT': str(args.port)},
        'interval': 5, 'probe_timeout': 2, 'lockup_timeout': 60,
        'boot_timeout': 120, 'max_attempts': 3, 'backoff': 10, 'stable_seconds': 300
    }
    state = Path(args.state_dir).resolve()
    if any((root / 'credentials' / name).exists() for name in ('intent-v1.json', 'intent-blocked-v1.json', 'intent-required-v1')) or (state / 'credential-intent-v1.json').exists():
        parser.error('existing protected history: preserve it and use compatible reconciliation, never reinstall')
    entries, revision = {}, 0
    originals = []
    sidecar = state / 'settings-noncredentials-v1.json'
    if sidecar.exists():
        ordinary = read_json(sidecar)
        if not isinstance(ordinary, dict) or type(ordinary.get('schema_version')) is not int or ordinary.get('schema_version') != 1 or not isinstance(ordinary.get('values'), dict) or any(canonical_setting(key)[1] or canonical_setting(key)[0] not in NONSECRET_SETTINGS or key != canonical_setting(key)[0] for key in ordinary['values']):
            parser.error('invalid noncredential settings document; preserve originals and reconcile offline')
        originals.append(('primary-settings-noncredentials-v1.json', sidecar.read_bytes()))

    for name in ('settings.json', 'chatgpt_auth.json'):
        source, backup = state / name, root / 'credentials' / name
        if args.new_installation and (source.exists() or backup.exists()):
            parser.error('new installation must have no legacy credential files')
        current = read_json(source) if source.exists() else {}
        old = read_json(backup) if backup.exists() else {}
        if not isinstance(current, dict) or not isinstance(old, dict) or (old and (not current or current != old)):
            parser.error('missing/conflicting legacy authority; reconcile offline; originals untouched')
        if name == 'chatgpt_auth.json' and current and not valid_credentials(source):
            parser.error('invalid legacy auth record; reconcile offline')
        for location, path in [('primary', source), ('backup', backup)]:
            if path.exists():
                originals.append((location + '-' + name, path.read_bytes()))
        values = [('chatgpt_auth.json', current)] if name == 'chatgpt_auth.json' and current else []
        if name == 'settings.json':
            try:
                current = canonical_settings(current)
            except ValueError:
                parser.error('conflicting legacy aliases; originals untouched')
            values = [('settings/' + key, value) for key, value in current.items()
                      if canonical_setting(key)[1]]
        for key, value in values:
            if key.startswith('settings/') and not isinstance(value, str):
                parser.error('invalid legacy secret value; originals untouched')
            revision += 1
            entries[key] = dict(state='enabled', version=revision, generation=revision, value=value)
    evidence = root / 'credentials' / ('legacy-' + __import__('uuid').uuid4().hex)
    for name, data in originals:
        atomic(evidence / name, data)
    intent = dict(schema_version=1, revision=revision, entries=entries)
    atomic(root / 'credentials' / 'intent-required-v1', b'1\n')
    atomic(root / 'credentials' / 'intent-blocked-v1.json', b'{"schema_version":1}')
    atomic(root / 'credentials' / 'intent-v1.json', json.dumps(intent).encode())
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic(state / 'credential-intent-v1.json', json.dumps(intent).encode())
    for name in ('settings.json', 'chatgpt_auth.json'):
        source = state / name
        if valid_credentials(source):
            atomic(root / 'credentials' / name, source.read_bytes())
    (root / 'credentials' / 'intent-blocked-v1.json').unlink()
    fd = os.open(root / 'credentials', os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    atomic(root / 'runner.py', Path(__file__).with_name('runner.py').read_bytes())
    atomic(root / 'config.json', json.dumps(config, indent=2).encode())
    print('Safety net installed but NOT started. Review ' + str(root / 'config.json'))
    print('Next bin/start uses it. Root and credential copies are private; no secrets printed.')


if __name__ == '__main__':
    main()
