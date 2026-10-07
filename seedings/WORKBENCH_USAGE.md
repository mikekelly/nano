# Core workbench tools

These are ordinary Elixir modules, not added harness tools. Use them from eval.
Paths are unrestricted; supply explicit paths/cwd when working in a git worktree.
File errors are returned as `{:error, reason}`. Existing map keys remain compatible.

## Files

```elixir
alias Seedling.Files
Files.read("/app/lib/example.ex", offset: 0, lines: 100, bytes: 12000)
Files.write("/data/new/directory/file.txt", "content\n")
Files.edit("file", "small unique old text", "new text")
Files.edit("file", [{"unique first", "replacement"}, {"unique second", "replacement"}])
Files.grep(~r/def\s+run/, glob: "/app/lib/**/*.ex")
Files.ls("/app")
Files.find("/app/lib/**/*.ex")
Files.tail("/data/seedling/tasks/output.log", lines: 100, bytes: 12000)
```

`read` offsets are **zero-based line indices**, not the one-based offsets used
by some coding tools. Follow returned `next_offset` when `more` is true.
Caps are at most 500 lines and 24 KB. A byte-limited read preserves complete
lines rather than skipping the unreturned remainder. An oversized first line
is an error: increase the byte cap (up to 24 KB) or inspect with shell tools.
`write` creates parent directories. `edit/3` retains legacy `:ok` success;
`edit/2` provides a bounded diff. Every replacement matches the original file
exactly once; overlapping and no-op edits fail without changing the file.
`{:expected_one_match, 0}` means match exactly including whitespace/newlines;
counts above one mean add context to make the match unique. No fuzzy matching
is promised. Edits are a read/modify/write operation, not a concurrent-writer lock.

`grep` accepts literal binaries or Regex values, `ignore_case: true`, `context: 0..5`,
`glob:`, and `gitignore: false` to include ignored paths. Gitignore rules use git
itself (including nested rules/negations); an explicitly named file bypasses ignore
filtering for compatibility. Filtering invokes git per candidate and
can be slow on large trees. `find` uses the same ignore filtering. `ls` includes
dotfiles and marks directories with `/`; globs include dotfiles only with
`dotfiles: true`. Search matches are one-based and capped at 500 characters,
with a per-hit `clipped` flag. Context searches load each candidate file to
provide neighbors; no huge-file memory bound is promised. Read/tail total line
metadata scans the file, so these are not constant-time random-access readers.

Reads keep the head; tails keep the end. All cuts are indicated in metadata.
For long output, page the saved file rather than sending it wholesale into context.

## Shell and background commands

```elixir
alias Seedling.Shell
Shell.sh("pwd; echo done", cwd: "/app", timeout: 60000)
{:ok, worker} = Shell.start("mix test", notify: "your-agent-name",
  cwd: "/app", timeout: 120000)
Shell.kill(worker)
```

`sh` is for short commands only: it waits inside the transient eval task.
`start` returns immediately and sends
`{:shell_done, worker_pid, %{status: status, reason: reason, path: log_path,
bytes: total_bytes, elapsed_ms: elapsed}}` on completion. Output is on disk,
not in the completion event. Read with `Files.tail` or paged `Files.read`.
The shell merges stderr/stdout. Nonzero exit is returned normally; inspect
`status`. Timeout and explicit kill have distinct `reason` values.

Always pass `notify: "your-agent-name"` from an agent eval: default `self()`
is the temporary eval process, not the agent. Workers are unlinked/independent
and keep running through caller death; named recipients are resolved at delivery,
with a bounded retry when absent. This is **not** durable/acknowledged delivery:
a recipient can die just after lookup, retries expire, and no tasks or messages
survive node/container restart. OS process groups handle kill/timeout; deliberately
detached descendants can escape. Log retention is manual. These tools provide no
sandbox or privilege boundary. Timeout can be disabled with `:infinity`; long
commands should still use `start`, not a blocking `sh`.

## Related modules

See `DELEGATION_USAGE.md` for isolated model-context jobs; the delegation watcher
and a shell worker are different processes with different completion protocols.
See `/app/NOTES.md` for the available higher-level capability index.
