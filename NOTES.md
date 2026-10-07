# Seedling workbench

Branch: seedling/sol-workbench. Libraries under lib/seedling, without harness prompt changes.

## Files

`Seedling.Files` — `read(path, offset: 0, lines: 100); write(path, text); edit(path, old, new); ls(path); find(glob); grep(text, glob: glob); tail(path)`

Reads keep the head, shell tails keep the end. Caps: 24 KB, 500 lines/matches/entries. A clipped long line is reported; next_offset advances by lines.

## Shell / background tasks

`Seedling.Shell` — `start("mix test", notify: "sol", cwd: "/app", timeout: 120000); kill(pid); sh("pwd")`

Completion: {:shell_done, worker_pid, %{status: status, reason: reason, path: path, bytes: bytes}}. Output is on disk, not in event. Always pass notify: your agent name from eval (default self() is the transient eval task). Named recipient resolves after restart (60s retry). Workers are independent and appear as spawned processes. Python3 creates an OS process group; kill/timeout kills that group. No survival across node/container restart, no durable delivery acknowledgement; detached OS descendants can escape the group. Log files require manual retention. Use start, not sh, for long work.

## Validation and scope

Tests: test/seedling_test.exs. Validation: 229 tests passed (5 new), compile --warnings-as-errors and format --check-formatted passed. Existing test-source warnings remain. Live dashboard process classification also verified. In this image MIX_BUILD_PATH is shared across environments: unset it when testing (`env -u MIX_BUILD_PATH MIX_ENV=test mix test`) to avoid loading production beams. Other seedings are deliberately left for follow-on branches; this branch builds the reusable foundation and background-tasks seeding.
