"""Failure injections only into fresh private directories and children we own."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "safety_net/supervisor.py"
spec = importlib.util.spec_from_file_location("safety", SCRIPT)
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)

# A real isolated BEAM with the same heartbeat probes, without network/credentials.
BEAM = """
{:ok, _} = Supervisor.start_link([], strategy: :one_for_one, name: Nano.Supervisor)
{:ok, _} = Supervisor.start_link([], strategy: :one_for_one, name: NanoWeb.Endpoint)
File.write!(System.fetch_env!("SAFETY_NET_SESSION") <> "/child.pid", System.pid())
File.write!(System.fetch_env!("SAFETY_NET_SESSION") <> "/served", System.fetch_env!("SAFETY_NET_TOKEN"))
Process.sleep(:infinity)
"""


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="deneb-safety-")
        self.root = Path(self.tmp.name)
        self.home = self.root / "net"
        self.app = self.root / "app"
        self.state = self.root / "state"
        self.app.mkdir()
        self.state.mkdir()
        (self.app / "node.exs").write_text(BEAM)
        self.secret = b'{"refresh_token":"synthetic-r1","access_token":"synthetic-a1"}'
        (self.state / "chatgpt_auth.json").write_bytes(self.secret)
        (self.state / "settings.json").write_text('{"key":"synthetic"}')
        subprocess.run([sys.executable, str(SCRIPT), "--home", str(self.home), "install", "--app", str(self.app), "--state-dir", str(self.state), "--deps-dir", str(self.app / "deps")], check=True, capture_output=True)
        self.config = safety.load(self.home / "config.json")
        self.config.update(restart_via_container=False, command=["elixir", "--erl", "+S 2:2", "-r", str(self.home / "runtime/heartbeat.exs"), "node.exs"], heartbeat_timeout=3, boot_timeout=5, settle_seconds=0.1, poll_seconds=0.05, backoff_seconds=0.1)
        safety.save(self.home / "config.json", self.config)
        self.proc = None
        self.log = open(self.root / "supervisor.log", "wb")

    def tearDown(self):
        self.halt()
        self.log.close()
        self.tmp.cleanup()

    def start(self):
        command = ["/bin/sh", str(ROOT / "bin/start")] if getattr(self, "use_launcher", False) else [sys.executable, str(self.home / "runtime/supervisor.py"), "--home", str(self.home), "run"]
        self.proc = subprocess.Popen(command, stdout=self.log, stderr=self.log, env=dict(os.environ, MIX_ENV="test", SAFETY_NET_HOME=str(self.home)))

    def halt(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(timeout=10)

    def events(self):
        path = self.home / "reports.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()]

    def wait(self, predicate, timeout=15):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("condition timed out: " + (self.root / "supervisor.log").read_text()[-2000:])

    def known_good(self):
        self.start()
        self.wait(lambda: any(e["event"] == "known_good" for e in self.events()))
        return safety.load(self.home / "recovery.json")["good"]

    def test_stopped_beam_is_killed_and_fallback_runs(self):
        self.known_good()
        pidfile = next((self.home / "sessions").glob("*/child.pid"))
        pid = int(pidfile.read_text())
        before = time.monotonic()
        os.kill(pid, signal.SIGSTOP)
        self.wait(lambda: any(e.get("reason") == "heartbeat_timeout" for e in self.events()))
        self.wait(lambda: len([e for e in self.events() if e["event"] == "starting"]) == 2)
        self.assertLess(time.monotonic() - before, 7)
        self.assertTrue(self.events()[-1]["fallback"])

    def test_failed_boot_preserves_original_and_uses_known_good(self):
        good = self.known_good()
        self.halt()
        broken = "this is invalid Elixir (((\n"
        (self.app / "node.exs").write_text(broken)
        state = safety.load(self.home / "recovery.json")
        state.update(fallback=False)
        safety.save(self.home / "recovery.json", state)
        self.start()
        self.wait(lambda: len([e for e in self.events() if e["event"] == "starting"]) >= 3)
        self.assertEqual((self.app / "node.exs").read_text(), broken)
        starts = [e for e in self.events() if e["event"] == "starting"]
        self.assertEqual(starts[-1]["evidence"], good)
        self.assertEqual((Path(starts[-2]["evidence"]) / "node.exs").read_text(), broken)

    def test_deleted_and_empty_credentials_restore_latest_private_bytes(self):
        new = b'{"refresh_token":"synthetic-rotated","access_token":"synthetic-a2"}'
        staging = self.root / "staging"
        staging.write_bytes(new)
        safety.credential_write(self.home, self.config, self.state / "chatgpt_auth.json", staging)
        (self.state / "chatgpt_auth.json").unlink()
        (self.state / "settings.json").write_bytes(b"")
        self.assertEqual(set(safety.credentials(self.home, self.state)), set(safety.CREDENTIALS))
        self.assertEqual((self.state / "chatgpt_auth.json").read_bytes(), new)
        for path in (self.home / "credentials").iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.state / "settings.json").stat().st_mode & 0o777, 0o600)
        reports = (self.home / "reports.jsonl").read_text()
        self.assertNotIn("synthetic", reports)
        self.assertTrue(list((self.home / "evidence").iterdir()))

    def test_new_valid_file_is_never_replaced(self):
        newer = b'{"key":"newer"}'
        (self.state / "settings.json").write_bytes(newer)
        self.assertEqual(safety.credentials(self.home, self.state), [])
        self.assertEqual((self.home / "credentials/settings.json").read_bytes(), newer)

    def test_no_good_revision_parks_instead_of_recovery_loop(self):
        (self.app / "node.exs").write_text("invalid (((")
        self.start()
        self.wait(lambda: any(e["event"] == "exhausted" for e in self.events()))
        self.assertIsNone(self.proc.poll())
        self.assertEqual(len([e for e in self.events() if e["event"] == "starting"]), 1)

    def test_budget_persists_across_supervisor_restart(self):
        safety.save(self.home / "recovery.json", {"attempts": 3})
        self.start()
        self.wait(lambda: any(e["event"] == "exhausted" for e in self.events()))
        self.halt()
        self.start()
        self.wait(lambda: len([e for e in self.events() if e["event"] == "exhausted"]) == 2)
        self.assertFalse(any(e["event"] == "starting" for e in self.events()))

    def test_heartbeat_without_served_does_not_promote(self):
        (self.app / "node.exs").write_text(BEAM.replace('File.write!(System.fetch_env!("SAFETY_NET_SESSION") <> "/served", System.fetch_env!("SAFETY_NET_TOKEN"))', ""))
        self.start()
        self.wait(lambda: list((self.home / "sessions").glob("*/heartbeat")))
        time.sleep(0.5)
        self.assertFalse(any(e["event"] == "known_good" for e in self.events()))

    def test_future_dated_stopped_heartbeat_does_not_extend_lease(self):
        self.known_good()
        session = next((self.home / "sessions").iterdir())
        os.kill(int((session / "child.pid").read_text()), signal.SIGSTOP)
        future = time.time() + 3600
        os.utime(session / "heartbeat", (future, future))
        self.wait(lambda: any(e.get("reason") == "heartbeat_timeout" for e in self.events()), timeout=7)

    def test_mutation_before_served_promotion_is_refused(self):
        self.config["settle_seconds"] = 1
        safety.save(self.home / "config.json", self.config)
        self.start()
        self.wait(lambda: list((self.home / "sessions").glob("*/heartbeat")))
        (self.app / "node.exs").write_text(BEAM + "\n# changed after capture\n")
        self.wait(lambda: any(e["event"] == "promotion_refused" for e in self.events()))
        self.assertNotIn("good", safety.load(self.home / "recovery.json"))

    def test_fallback_working_copy_cannot_mutate_good_snapshot(self):
        good = self.known_good()
        self.halt()
        state = safety.load(self.home / "recovery.json")
        state["fallback"] = True
        safety.save(self.home / "recovery.json", state)
        self.start()
        self.wait(lambda: len([e for e in self.events() if e["event"] == "starting"]) == 2)
        active = Path(safety.load(self.home / "recovery.json")["active"])
        self.assertNotEqual(str(active), good)
        (active / "node.exs").write_text("mutated fallback working copy")
        self.assertEqual((Path(good) / "node.exs").read_text(), BEAM)

    def test_failed_target_write_replays_latest_rotation_not_old_primary(self):
        from unittest.mock import patch
        new = b'{"refresh_token":"synthetic-r2","access_token":"synthetic-a2"}'
        target = self.state / "chatgpt_auth.json"
        staging = self.root / "staged"
        staging.write_bytes(new)
        original = safety.atomic
        def fail_target(path, data):
            if Path(path) == target:
                raise OSError("injected target write failure")
            original(path, data)
        with patch.object(safety, "atomic", side_effect=fail_target):
            with self.assertRaises(OSError):
                safety.credential_write(self.home, self.config, target, staging)
        self.assertEqual(target.read_bytes(), self.secret)
        self.assertTrue((self.home / "pending/chatgpt_auth.json").exists())
        safety.credentials(self.home, self.state)
        self.assertEqual(target.read_bytes(), new)
        self.assertEqual((self.home / "credentials/chatgpt_auth.json").read_bytes(), new)
        self.assertFalse((self.home / "pending/chatgpt_auth.json").exists())

    def test_intentional_forget_and_empty_settings_stay_forgotten(self):
        target = self.state / "chatgpt_auth.json"
        safety.credential_forget(self.home, self.config, target)
        self.assertEqual(safety.credentials(self.home, self.state), [])
        self.assertFalse(target.exists())
        staging = self.root / "staged"
        staging.write_bytes(self.secret)
        safety.credential_write(self.home, self.config, target, staging)
        target.unlink()
        safety.credentials(self.home, self.state)
        self.assertEqual(target.read_bytes(), self.secret)
        staging.write_text("{}")
        safety.credential_write(self.home, self.config, self.state / "settings.json", staging)
        self.assertEqual(safety.credentials(self.home, self.state), [])
        self.assertEqual((self.state / "settings.json").read_text(), "{}")

    def test_partial_install_does_not_replace_original_launcher(self):
        (self.home / "config.json").unlink()
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        executable = fake_bin / "elixir"
        executable.write_text("#!/bin/sh\nprintf 'original-launch-fallback\\n'\n")
        executable.chmod(0o700)
        result = subprocess.run(["/bin/sh", str(ROOT / "bin/start")], env=dict(os.environ, SAFETY_NET_HOME=str(self.home), NODE_COOKIE="synthetic", PATH=str(fake_bin) + ":" + os.environ["PATH"]), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("original-launch-fallback", result.stdout)
        self.assertIn("unprotected", result.stderr)

    def test_container_restart_handoff_persists_fallback(self):

        self.use_launcher = True
        self.config["restart_via_container"] = True
        safety.save(self.home / "config.json", self.config)
        good = self.known_good()
        pidfile = next((self.home / "sessions").glob("*/child.pid"))
        os.kill(int(pidfile.read_text()), signal.SIGSTOP)
        self.wait(lambda: self.proc.poll() is not None)
        self.assertEqual(self.proc.returncode, 75)
        state = safety.load(self.home / "recovery.json")
        self.assertTrue(state["fallback"])
        self.assertEqual(state["good"], good)
        # Emulate only launcher re-execution, not a Docker/cgroup cleanup claim.
        self.start()
        self.wait(lambda: len([e for e in self.events() if e["event"] == "starting"]) == 2)
        self.assertTrue([e for e in self.events() if e["event"] == "starting"][-1]["fallback"])

    def test_external_dependency_path_is_copied_into_baseline(self):

        external = self.root / "external-deps"
        external.mkdir()
        (external / "fixture.ex").write_text("dependency source")
        self.config["deps_dir"] = str(external)
        safety.save(self.home / "config.json", self.config)
        good = self.known_good()
        self.assertFalse((self.app / "deps").exists())
        self.assertEqual((Path(good) / "deps/fixture.ex").read_text(), "dependency source")
        (external / "fixture.ex").write_text("broken new dependency")
        self.assertEqual((Path(good) / "deps/fixture.ex").read_text(), "dependency source")

    def test_forget_crash_replays_forget_not_prior_pending_write(self):
        from unittest.mock import patch
        target = self.state / "chatgpt_auth.json"
        safety.save(self.home / "pending/chatgpt_auth.json", {"operation": "write", "bytes": "not relevant; overwritten by forget"})
        original = safety.atomic
        def fail_tombstone(path, data):
            if Path(path) == self.home / "forgotten/chatgpt_auth.json":
                raise OSError("injected interruption after forget journal")
            original(path, data)
        with patch.object(safety, "atomic", side_effect=fail_tombstone):
            with self.assertRaises(OSError):
                safety.credential_forget(self.home, self.config, target)
        self.assertEqual(safety.load(self.home / "pending/chatgpt_auth.json")["operation"], "forget")
        self.assertIn("chatgpt_auth.json", safety.credentials(self.home, self.state))
        self.assertFalse(target.exists())
        self.assertFalse((self.home / "credentials/chatgpt_auth.json").exists())
        self.assertTrue((self.home / "forgotten/chatgpt_auth.json").exists())

    def test_writer_error_marker_requests_bounded_reload(self):
        self.known_good()
        safety.atomic(self.home / "reload_requested", b"credential persistence failed\n")
        self.wait(lambda: any(e.get("reason") == "credential_writer_requires_reload" for e in self.events()))

    def test_elixir_writer_roundtrip_and_forget(self):

        target = self.state / "settings.json"
        code = 'path = System.fetch_env!("TEST_TARGET"); :ok = SafetyNet.write_credential(path, ~s({"key":"synthetic-api"})); :ok = SafetyNet.forget_credential(path); IO.puts("transaction-ok")'
        result = subprocess.run(["elixir", "--erl", "+S 2:2", "-r", str(ROOT / "lib/safety_net.ex"), "-e", code], env=dict(os.environ, SAFETY_NET_HOME=str(self.home), TEST_TARGET=str(target)), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("transaction-ok", result.stdout)
        self.assertFalse(target.exists())
        self.assertTrue((self.home / "forgotten/settings.json").exists())
        self.assertFalse(list(self.state.glob("*.safety-*")))

    def test_missing_installed_writer_never_acknowledges_save(self):

        (self.home / "runtime/supervisor.py").unlink()
        target = self.state / "settings.json"
        before = target.read_bytes()
        code = 'IO.inspect(SafetyNet.write_credential(System.fetch_env!("TEST_TARGET"), "{}"))'
        result = subprocess.run(["elixir", "--erl", "+S 2:2", "-r", str(ROOT / "lib/safety_net.ex"), "-e", code], env=dict(os.environ, SAFETY_NET_HOME=str(self.home), TEST_TARGET=str(target)), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0)
        self.assertIn("{:error, :safety_runtime_unavailable}", result.stdout)
        self.assertEqual(target.read_bytes(), before)

    def test_corrupt_metadata_parks_without_exiting(self):
        (self.home / "recovery.json").write_text("invalid json")
        self.start()
        self.wait(lambda: "supervisor failed" in (self.root / "supervisor.log").read_text())
        self.assertIsNone(self.proc.poll())
        self.assertFalse(any(e["event"] == "starting" for e in self.events()))

    def test_full_disposable_app_compile_failure_rolls_back(self):

        # Copy source + immutable dependency bytes, never live state or credentials.
        import shutil
        shutil.rmtree(self.app)
        shutil.copytree(ROOT, self.app, ignore=lambda _p, names: [n for n in names if n in safety.EXCLUDE])
        expression = 'File.write!(System.fetch_env!("SAFETY_NET_SESSION") <> "/served", System.fetch_env!("SAFETY_NET_TOKEN")); File.write!(System.fetch_env!("SAFETY_NET_SESSION") <> "/test_dir", Application.fetch_env!(:nano, :test_dir))'
        self.config.update(deps_dir=str(self.app / "deps"), command=["elixir", "--erl", "+S 2:2", "-r", str(self.home / "runtime/heartbeat.exs"), "-S", "mix", "run", "--no-halt", "-e", expression], boot_timeout=90)
        safety.save(self.home / "config.json", self.config)
        try:
            self.start()
            self.wait(lambda: any(e["event"] == "known_good" for e in self.events()), timeout=100)
            good = safety.load(self.home / "recovery.json")["good"]
            self.halt()
            (self.app / "lib/injected_failure.ex").write_text("defmodule BROKEN (((")
            state = safety.load(self.home / "recovery.json")
            state.update(fallback=False)
            safety.save(self.home / "recovery.json", state)
            self.start()
            self.wait(lambda: len([e for e in self.events() if e["event"] == "starting"]) >= 3, timeout=100)
            self.wait(lambda: len(list((self.home / "sessions").glob("*/test_dir"))) == 2, timeout=100)
            self.assertEqual([e for e in self.events() if e["event"] == "starting"][-1]["evidence"], good)
            self.assertTrue((self.app / "lib/injected_failure.ex").exists())
        finally:
            self.halt()
            for path in (self.home / "sessions").glob("*/test_dir"):
                data = Path(path.read_text())
                if data.parent == Path(tempfile.gettempdir()) and data.name.startswith("nano-test-"):
                    shutil.rmtree(data, ignore_errors=True)

    def test_credential_loss_while_running_forces_reload(self):

        self.known_good()
        (self.state / "chatgpt_auth.json").unlink()
        self.wait(lambda: any(e.get("reason") == "credentials_reload" for e in self.events()))
        self.assertEqual((self.state / "chatgpt_auth.json").read_bytes(), self.secret)


if __name__ == "__main__":
    unittest.main(verbosity=2)
