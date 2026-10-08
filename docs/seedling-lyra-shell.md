# Shell and background commands

- `Seedling.Shell.sh("mix test", cwd: "/app", timeout: 20_000)` returns
  `{:ok, metadata}` with bounded tail, exit code, status, output/receipt paths.
  Defaults: last 200 lines / 16 KB; full stdout+stderr retained on disk.
- `Seedling.Background.start("mix test", owner: "lyra", cwd: "/app")` returns
  `{:ok, task}` promptly. Use `status(task)`, `cancel(task)`, `receipt(path)`.
  Completion: `{:seedling_background, receipt}` with bytes/path, no output.
- Options: `cwd`, `env` (key/value list, nil unsets), `timeout` (ms or :infinity),
  `dir` (default /data/seedling/background), `owner` (name preferred, pid supported).
- Workers are unlinked GenServers owning setsid/bash ports. Agent/eval restarts do
  not kill them. Named ownership is inferred from callers and re-resolved every
  second for dashboard attribution and at completion; delivery waits if name absent.
  Atomic terminal receipts allow status after worker exit. Tests exercise actual OS
  commands, env/cwd/nonzero exit, bounded logs, cancel/timeout, caller death, named
  owner replacement and Nano.Ops ownership: 5 passed in isolated MIX_ENV=test build.

Limitations: not BEAM/host restart recovery; terminal receipts/logs persist but running
commands are not reconstructed. Mailbox delivery is not acknowledged/exactly-once;
restart between send and processing may lose notification (receipt remains readable).
Named owners that never return retain a waiting worker. Trusted POSIX commands only;
commands escaping their process group cannot be cancelled reliably. Use cancel(task),
not brutal dashboard process kill (which cannot guarantee descendant cleanup).
setsid can print a diagnostic when killed; retained as merged output. No live code loaded.
