# Background jobs

`Seedling.Background.start(command, owner: agent_name, cwd: path, timeout: ms, env: [{key,value}])` returns `{:ok,pid,id}` immediately. `info(pid)` inspects while it runs; `cancel(pid)` kills the whole shell session. Completion arrives by name, never a stale agent PID, as `%{background: id,status: code,reason: :exit | :timeout | :cancelled,output: path,bytes: size}`. `tail(path, lines: 100, bytes: 12000)` reads a bounded tail. Metadata/output/results persist under `/data/background/<owner>/<id>`. The dashboard attributes the unlinked worker to the owner through `$callers`; verified by test. Detached workers and their ports survive eval/caller and agent restarts. They do not survive a node/container restart. Do not kill the BEAM worker directly: use `cancel/1` to kill the OS session and receive completion.

Uses util-linux `setsid --wait` and coreutils `kill` installed in image. `--wait` matters: a bare setsid can fork, causing a false completion before command output finishes. `session.pid` identifies the new shell process-group (which can differ from the port's OS PID). Timeout kills that group, not unrelated machine tasks.

Tests use unique temp roots and scripted provider; four tests passed: output and exit ordering, timeout, caller death/cancellation, real NanoAgent process restart/completion/dashboard attribution. No real model expenditure.
