# Nano.Tools and Nano.Background

All helpers return `{:ok, map}` or `{:error, reason}` (kill returns `:ok`).

```elixir
Nano.Tools.read("lib/nano_agent.ex", offset: 1, limit: 100)
Nano.Tools.write("/tmp/my-agent/new.txt", "content")
Nano.Tools.edit("/tmp/my-agent/new.txt", "content", "replacement")
Nano.Tools.edit(path, [{old1, new1}, {old2, new2}])
Nano.Tools.ls("lib")
Nano.Tools.find("**/*.ex", cwd: "lib")
Nano.Tools.grep("def start", path: "lib", literal: true)
Nano.Tools.sh("mix test", cwd: "/tmp/my-worktree", timeout: 30000)
{:ok, job} = Nano.Background.start("mix test", cwd: "/tmp/my-worktree", notify: "nova", timeout: 120000)
Nano.Background.status(job.id)
Nano.Background.tail(job.id, limit: 50)
Nano.Background.kill(job.id)
```

Reads are line-paged (1-based offset), default 200 lines/16KB, head retained,
next_offset provided; oversized single lines error rather than silently truncate.
Tail keeps 200 lines/16KB and announces truncation. Writes create parents. Edits
require one exact occurrence per replacement, reject overlaps and unchanged text,
and preserve untouched bytes/line endings. No tolerant matching or diff generation.
Listings cap 500 entries; find caps 1000 paths; grep caps 100 matches with 500
characters per matching line. Find/grep respect git ignore via git check-ignore
when inside a repository (`respect_gitignore: false` disables). Grep supports regex,
literal, ignore_case, glob, limit and line_limit; context lines are not implemented.
Results are maps for branching, not formatted CLI output. Read/tail currently load
whole files; find enumerates the glob before capping. Result bounds do not imply
bounded input memory or search runtime. Tail byte slicing drops incomplete leading UTF-8 characters.

Background workers and the manager are unlinked to evals. Worker ancestry includes
caller chains for dashboard attribution even after the eval dies. Default notify
resolves the calling agent's stable name; otherwise defaults to caller pid. Explicit
notify name retries delivery while the agent is absent. Completion events contain
`{:nano_background, id, %{state: ..., exit_status: ..., bytes: ..., path: ...,
duration_ms: ...}}`, never output. pid notification cannot survive pid replacement.
Linux setsid --wait isolates a process group; timeout/kill sends SIGKILL to the group
(including ordinary children). Daemons that deliberately escape their group aren't
controlled. Output goes to uniquely named files under /tmp/nano-background by default;
set output_dir for durable storage. Files and completed metadata are retained until
manual cleanup/node exit; there is no retention scheduler. Jobs survive agent restart,
not node/container restart. Do not write secrets to commands/output.

Tests: `MIX_ENV=test MIX_BUILD_ROOT=/tmp/nova-tools/_build mix test test/nano/tools_test.exs test/nano/background_test.exs`.

Listings, find and grep also cap aggregate inspected item bytes at 16KB (`max_bytes`), with `offset`/`next_offset` for exact continuation. A single oversized item errors. Tail can be continued by `read(path, offset: 1)` or increasing `limit`/`max_bytes`; full output remains at path.
