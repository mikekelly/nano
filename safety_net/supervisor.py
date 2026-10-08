#!/usr/bin/env python3
"""External safety supervisor. See docs/safety-net.md.
Never import application code or signal processes not started by us.
"""
import argparse
import base64
import contextlib
import datetime
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
import tempfile
import time
import uuid

OWNED_CHILD = None
RUNTIME_HOME = None
SUPERVISOR_LOCK = None

CREDENTIALS = ("settings.json", "chatgpt_auth.json")
EXCLUDE = {".git", "_build", "tmp", "data", "archive", ".claude", "node_modules", "erl_crash.dump", "__pycache__"}


def atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix=".safety-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load(path, default=None):
    try:
        return json.loads(Path(path).read_bytes())
    except FileNotFoundError:
        return default


def save(path, value):
    atomic(path, json.dumps(value, sort_keys=True).encode())


def report(home, event, **fields):
    record = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(), event=event, **fields)
    line = json.dumps(record, sort_keys=True)
    with open(home / "reports.jsonl", "a", encoding="utf-8") as out:
        os.chmod(home / "reports.jsonl", 0o600)
        out.write(line + "\n")
        out.flush()
        os.fsync(out.fileno())
    save(home / "status.json", record)
    print("SAFETY NET: " + line, file=sys.stderr, flush=True)


def valid(data, name):
    try:
        obj = json.loads(data)
        if not isinstance(obj, dict) or not obj:
            return False
        if name == "chatgpt_auth.json":
            return all(isinstance(obj.get(k), str) and obj[k].strip() for k in ("refresh_token", "access_token"))
        return True
    except (ValueError, UnicodeError):
        return False


def read_regular(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("not a regular file")
        with os.fdopen(fd, "rb", closefd=False) as src:
            data = src.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError("credential file too large")
        return data
    finally:
        os.close(fd)


def journal_finish(home, state_dir, name):
    journal = home / "pending" / name
    pending = load(journal)
    if pending is None:
        return False
    target = Path(state_dir) / name
    if pending.get("operation") == "forget":
        atomic(home / "forgotten" / name, b"intentional removal\n")
        for path in (home / "credentials" / name, target):
            if path.exists():
                path.unlink()
                sync_dir(path.parent)
        journal.unlink()
        sync_dir(journal.parent)
        return True
    if pending.get("operation") != "write":
        raise ValueError("invalid credential journal operation")
    data = base64.b64decode(pending["bytes"], validate=True)
    if not valid(data, name) and not (name == "settings.json" and json.loads(data) == {}):
        raise ValueError("invalid credential journal bytes")
    current = read_regular(target)
    current_sha = hashlib.sha256(current).hexdigest() if current is not None else None
    if current is not None and valid(current, name) and current != data and current_sha != pending["previous_sha"]:
        report(home, "credential_write_conflict", file=name, action="preserved both; inspection required")
        raise ValueError("noncooperating credential writer conflict")
    # Replay write-ahead journal before treating an old primary as authoritative.
    atomic(home / "credentials" / name, data)
    atomic(target, data)
    forgotten = home / "forgotten" / name
    if name == "settings.json" and json.loads(data) == {}:
        atomic(forgotten, b"intentional empty settings\n")
    elif forgotten.exists():
        forgotten.unlink()
        sync_dir(forgotten.parent)
    journal.unlink()
    sync_dir(journal.parent)
    return True


def sync_dir(directory):
    fd = os.open(directory, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def credentials(home, state_dir, restore=True):
    """Serialize backup/restore/write-ahead replay with the integrated writers."""
    if (home / "disabled").exists():
        return []
    restored = []
    with open(home / "credentials.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for name in CREDENTIALS:
            if journal_finish(home, state_dir, name):
                restored.append(name)
                report(home, "credential_pending_replayed", file=name, action="reload latest durable write")
            if (home / "forgotten" / name).exists():
                continue
            target = Path(state_dir) / name
            backup = home / "credentials" / name
            data = read_regular(target)
            if data is not None and valid(data, name):
                if read_regular(backup) != data:
                    atomic(backup, data)
                os.chmod(backup, 0o600)
            elif restore and backup.exists():
                good = read_regular(backup)
                if not valid(good, name):
                    report(home, "invalid_backup", file=name)
                    continue
                if read_regular(target) != data:
                    continue
                evidence = None
                if data is not None:
                    evidence = "evidence/" + uuid.uuid4().hex + "-" + name
                    atomic(home / evidence, data)
                atomic(target, good)
                restored.append(name)
                report(home, "credentials_restored", file=name, evidence=evidence)
    return restored


def configured_target(config, target):
    target = Path(target).resolve()
    expected = Path(config["state_dir"]).resolve() / target.name
    if target != expected or target.name not in CREDENTIALS:
        raise ValueError("not a configured credential path")
    return target


def credential_forget(home, config, target):
    target = configured_target(config, target)
    with open(home / "credentials.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Replace any pending write with a durable forget operation. A crash at any
        # subsequent step replays forget, never resurrects an older pending write.
        save(home / "pending" / target.name, {"operation": "forget"})
        journal_finish(home, config["state_dir"], target.name)
        report(home, "credential_forgotten", file=target.name, action="automatic restoration suppressed until next save")


def credential_write(home, config, target, staging):
    target = configured_target(config, target)
    data = read_regular(staging)
    if data is None:
        raise ValueError("missing staging file")
    # {} supplied through the integrated Settings writer means intentional clearing.
    empty_settings = target.name == "settings.json" and json.loads(data) == {}
    if not empty_settings and not valid(data, target.name):
        raise ValueError("malformed credential write")
    with open(home / "credentials.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        journal_finish(home, config["state_dir"], target.name)
        current = read_regular(target)
        save(home / "pending" / target.name, {"operation": "write", "bytes": base64.b64encode(data).decode(), "previous_sha": hashlib.sha256(current).hexdigest() if current is not None else None})
        journal_finish(home, config["state_dir"], target.name)
        forgotten = home / "forgotten" / target.name
        if empty_settings:
            atomic(forgotten, b"intentional empty settings\n")
        elif forgotten.exists():
            forgotten.unlink()
            sync_dir(forgotten.parent)


def fingerprint(source, skip_root_deps=False):
    digest = hashlib.sha256()
    visited = set()
    total = 0
    count = 0
    deadline = time.monotonic() + 30
    for directory, dirs, files in os.walk(source, followlinks=True):
        real = os.path.realpath(directory)
        if real in visited:
            raise ValueError("cyclic or aliased source directory")
        visited.add(real)
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDE and not (skip_root_deps and Path(directory) == Path(source) and d == "deps"))
        for name in sorted(files):
            if name in EXCLUDE or name == "safety-snapshot.json":
                continue
            path = Path(directory) / name
            if not path.is_file():
                raise ValueError("nonregular source input")
            digest.update(str(path.relative_to(source)).encode() + b"\0")
            digest.update(str(path.stat().st_mode & 0o111).encode() + b"\0")
            count += 1
            if count > 50000:
                raise ValueError("source file-count limit")
            with open(path, "rb") as stream:
                while chunk := stream.read(1024 * 1024):
                    total += len(chunk)
                    if total > 512 * 1024 * 1024 or time.monotonic() > deadline:
                        raise ValueError("source size or fingerprint time limit")
                    digest.update(chunk)
    return digest.hexdigest()


def source_fingerprint(app, deps=None):
    return hashlib.sha256((fingerprint(app, skip_root_deps=True) + ":" + (fingerprint(deps) if deps and Path(deps).is_dir() else "no-dependencies")).encode()).hexdigest()


def snapshot(home, app, deps=None):
    before = source_fingerprint(app, deps)
    dest = home / "snapshots" / uuid.uuid4().hex
    shutil.copytree(app, dest, ignore=lambda p, names: [n for n in names if n in EXCLUDE or (Path(p) == Path(app) and n == "deps")])
    if deps and Path(deps).is_dir():
        shutil.copytree(deps, dest / "deps", ignore=lambda _p, names: [n for n in names if n in EXCLUDE])
    after = source_fingerprint(app, deps)
    copied = source_fingerprint(dest, dest / "deps")
    if before != after or before != copied:
        report(home, "source_changed_during_capture", evidence=str(dest), action="preserved; retry after edits settle")
        raise ValueError("source changed while copying")
    revision = subprocess.run(["git", "-C", str(app), "rev-parse", "HEAD"], capture_output=True, text=True)
    save(dest / "safety-snapshot.json", dict(revision=revision.stdout.strip() if revision.returncode == 0 else None, sha256=copied))
    return str(dest)


def stop(child):
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()


def token_matches(path, token):
    try:
        return path.read_text().strip() == token
    except FileNotFoundError:
        return False


def run(home):
    global OWNED_CHILD, SUPERVISOR_LOCK
    # Keep singleton ownership even if an exception unwinds into the parked handler.
    SUPERVISOR_LOCK = open(home / "supervisor.lock", "a")
    with contextlib.nullcontext(SUPERVISOR_LOCK) as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("safety supervisor already running")
        config = load(home / "config.json")
        if (home / "disabled").exists():
            report(home, "disabled", protected=False)
            os.chdir(config["app"])
            os.execvpe(config["command"][0], config["command"], os.environ)
        while True:
            state = load(home / "recovery.json", {"attempts": 0})
            if state["attempts"] >= config["max_attempts"]:
                report(home, "exhausted", protected=False, attempts=state["attempts"], action="parked; inspect then reset")
                while True:
                    time.sleep(60)
            fallback = state.get("fallback", False)
            state.update(attempts=state["attempts"] + 1, fallback=True)
            save(home / "recovery.json", state)
            credentials(home, config["state_dir"])
            (home / "reload_requested").unlink(missing_ok=True)
            candidate = state.get("good") if fallback else snapshot(home, config["app"], config.get("deps_dir"))
            if not candidate or not Path(candidate).is_dir():
                state["attempts"] = config["max_attempts"]
                save(home / "recovery.json", state)
                report(home, "no_known_good", action="parking; original app untouched")
                continue
            manifest = load(Path(candidate) / "safety-snapshot.json")
            if source_fingerprint(candidate, Path(candidate) / "deps") != manifest["sha256"]:
                raise ValueError("known good evidence was modified")
            token = uuid.uuid4().hex
            session = home / "sessions" / token
            session.mkdir(parents=True, mode=0o700)
            if fallback:
                source = str(home / "runs" / token)
                shutil.copytree(candidate, source)
            else:
                source = config["app"]
            state.update(active=source, candidate=candidate)
            save(home / "recovery.json", state)
            env = dict(os.environ, SAFETY_NET_HOME=str(home), SAFETY_NET_SESSION=str(session), SAFETY_NET_TOKEN=token)
            env.pop("MIX_BUILD_ROOT", None)
            env["MIX_BUILD_PATH"] = str(home / "builds" / token)
            env["MIX_DEPS_PATH"] = str(Path(source) / "deps") if fallback else (config.get("deps_dir") or str(Path(source) / "deps"))
            report(home, "starting", source=source, evidence=candidate, fallback=fallback, attempt=state["attempts"], supervisor_pid=os.getpid(), session=token)
            child = subprocess.Popen(config["command"], cwd=source, env=env, start_new_session=True)
            OWNED_CHILD = child
            def terminate(_signum, _frame):
                stop(child)
                raise SystemExit(0)
            signal.signal(signal.SIGTERM, terminate)
            signal.signal(signal.SIGINT, terminate)
            start = time.monotonic()
            last = start
            last_stamp = None
            ready_since = None
            promoted = fallback
            reason = "child_exit"
            while child.poll() is None:
                now = time.monotonic()
                if credentials(home, config["state_dir"]):
                    reason = "credentials_reload"
                    break
                if (home / "reload_requested").exists():
                    reason = "credential_writer_requires_reload"
                    break
                heartbeat = session / "heartbeat"
                if token_matches(heartbeat, token):
                    stamp = heartbeat.stat().st_mtime_ns
                    if stamp != last_stamp:
                        last_stamp = stamp
                        last = now
                        save(home / "monitor.json", dict(supervisor_pid=os.getpid(), child_pid=child.pid, session=token, observed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), disabled=(home / "disabled").exists(), heartbeat_age_seconds=0))
                        if ready_since is None:
                            ready_since = now
                if ready_since is None and now - start > config["boot_timeout"]:
                    reason = "boot_timeout"
                    break
                if ready_since is not None and now - last > config["heartbeat_timeout"]:
                    reason = "heartbeat_timeout"
                    break
                if not promoted and ready_since is not None and now - ready_since >= config["settle_seconds"] and token_matches(session / "served", token):
                    promoted = True
                    if source_fingerprint(source, config.get("deps_dir")) != manifest["sha256"] or source_fingerprint(candidate, Path(candidate) / "deps") != manifest["sha256"]:
                        report(home, "promotion_refused", reason="source changed since boot capture", evidence=candidate)
                        continue
                    state.update(good=candidate, attempts=0, fallback=False)
                    save(home / "recovery.json", state)
                    report(home, "known_good", source=source, evidence=candidate, proof="heartbeat and successful model response")
                    promoted = True
                time.sleep(config["poll_seconds"])
            stop(child)
            OWNED_CHILD = None
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            state = load(home / "recovery.json")
            state.update(attempts=max(1, state["attempts"]), fallback=True)
            save(home / "recovery.json", state)
            report(home, "recovery", reason=reason, evidence=candidate, action="retry known-good; app untouched")
            time.sleep(config["backoff_seconds"])
            if config.get("restart_via_container", True):
                # Docker tears down detached OS descendants too; next launcher reads the
                # durable fallback/budget state. Standalone retry is for isolated tests.
                return 75


def install(args, home):
    if (home / "config.json").exists():
        raise SystemExit("already installed; review and update runtime explicitly")
    runtime = home / "runtime"
    runtime.mkdir(parents=True, mode=0o700)
    for name in ("supervisor.py", "heartbeat.exs", "launch"):
        shutil.copyfile(Path(__file__).parent / name, runtime / name)
        os.chmod(runtime / name, 0o700)
    command = ["/bin/sh", str(runtime / "launch")]
    deps = Path(args.deps_dir or os.environ.get("MIX_DEPS_PATH", str(Path(args.app) / "deps"))).resolve()
    save(home / "config.json", dict(restart_via_container=True, deps_dir=str(deps) if deps.is_dir() else None, app=str(Path(args.app).resolve()), state_dir=str(Path(args.state_dir).resolve()), command=command, max_attempts=3, boot_timeout=120, heartbeat_timeout=60, settle_seconds=30, poll_seconds=0.25, backoff_seconds=10))
    credentials(home, args.state_dir, restore=False)
    report(home, "installed", protected=False, restart_policy="external_not_verified", backups={name: (home / "credentials" / name).exists() for name in CREDENTIALS}, action="armed for next bin/start; not monitoring live node")


def main():
    global RUNTIME_HOME
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", default=os.environ.get("SAFETY_NET_HOME", "/data/safety-net"))
    parser.add_argument("action", choices=["install", "run", "status", "reset", "backup", "write", "forget"])
    parser.add_argument("--app", default="/app")
    parser.add_argument("--state-dir", default="/data/state")
    parser.add_argument("--deps-dir")
    parser.add_argument("--input")
    parser.add_argument("--target")
    args = parser.parse_args()
    home = Path(args.home).resolve()
    RUNTIME_HOME = home
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(home, 0o700)
    if args.action == "install":
        install(args, home)
    elif args.action == "run":
        sys.exit(run(home) or 0)
    elif args.action == "status":
        print(json.dumps({"status": load(home / "status.json"), "monitor": load(home / "monitor.json"), "liveness": "unknown; inspect monitor timestamp", "restart_policy": "external_not_verified", "recovery": load(home / "recovery.json"), "disabled": (home / "disabled").exists()}, indent=2))
    elif args.action == "forget":
        credential_forget(home, load(home / "config.json"), args.target)
    elif args.action == "write":
        credential_write(home, load(home / "config.json"), args.target, args.input)
    elif args.action == "backup":
        config = load(home / "config.json")
        credentials(home, config["state_dir"], restore=False)
    elif args.action == "reset":
        with open(home / "supervisor.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = load(home / "recovery.json", {})
            state.update(attempts=0, fallback=False)
            save(home / "recovery.json", state)
            report(home, "reset", protected=False, action="next boot tries current app")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("SAFETY NET: supervisor failed (" + type(error).__name__ + "); inspect private state", file=sys.stderr)
        if "run" in sys.argv:
            try:
                report(RUNTIME_HOME, "runtime_failed", protected=False, reason=type(error).__name__, action="parked; inspect private state")
            except Exception:
                pass
            if OWNED_CHILD is not None:
                stop(OWNED_CHILD)
            # Fail closed without a Docker restart storm, even on corrupt metadata.
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            while True:
                time.sleep(60)
        sys.exit(70)
