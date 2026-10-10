#!/usr/bin/env python3
"""Explicit installer: never starts a process, never changes bin/start or /app."""
import argparse
import json
import os
from pathlib import Path
import shutil
from runner import atomic, valid_credentials


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true', help='Required acknowledgement: credential writers are stopped for maintenance')
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
    if (root / 'config.json').exists():
        parser.error('already installed; review existing config rather than replacing it')
    app = Path(args.app).resolve()
    if root == app or root.is_relative_to(app):
        parser.error('safety root must be outside app checkout')
    if not (app / 'mix.exs').is_file():
        parser.error('app must contain mix.exs')
    if not shutil.which('python3') or not shutil.which('elixir'):
        parser.error('python3 and elixir are required at every container start')
    config = {
        'app': str(app), 'state_dir': str(Path(args.state_dir).resolve()),
        'health_url': 'http://127.0.0.1:%d/api/safety/health' % args.port,
        'command': ['sh', '-c', 'exec elixir --name nano@127.0.0.1 --cookie "${NODE_COOKIE:-$(cat /opt/nano/cookie)}" -S mix run --no-halt'],
        'env': {'MIX_ENV': 'prod', 'PORT': str(args.port)},
        'interval': 5, 'probe_timeout': 2, 'lockup_timeout': 60,
        'boot_timeout': 120, 'max_attempts': 3, 'backoff': 10, 'stable_seconds': 300
    }
    for name in ('settings.json', 'chatgpt_auth.json'):
        source = Path(args.state_dir) / name
        if valid_credentials(source):
            atomic(root / 'credentials' / name, source.read_bytes())
    atomic(root / 'runner.py', Path(__file__).with_name('runner.py').read_bytes())
    atomic(root / 'config.json', json.dumps(config, indent=2).encode())
    print('Safety net installed but NOT started. Review ' + str(root / 'config.json'))
    print('Next bin/start uses it. Root and credential copies are private; no secrets printed.')


if __name__ == '__main__':
    main()
