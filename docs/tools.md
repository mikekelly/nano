# File, shell and search helpers

`Seedling.Tools` is the small foundation for eval work. Start with this module's doc;
this page has options and return shapes. No harness modules are changed or required.

```elixir
alias Seedling.Tools, as: T
{:ok, page} = T.read("/app/lib/seedling/tools.ex", offset: 1, limit: 80)
page.text                         # complete lines, head retained
page.notice                       # exact continuation hint when capped
T.read("/app/lib/seedling/tools.ex", offset: page.next_offset)
T.write("/tmp/my-agent/new/file", "content\n")
T.edit("/tmp/my-agent/file", "small but unique old text", "new text")
T.edit("/tmp/my-agent/file", [{"old one", "new one"}, {"old two", "new two"}])
T.ls("/app/lib")
T.find("**/*_test.exs", cwd: "/app")
T.find("/app/lib/**/*.ex")         # absolute glob chooses its fixed prefix as cwd
T.grep("defmodule", "/app/lib", glob: "*.ex", context: 1)
T.sh("mix test", cwd: "/tmp/my-agent-worktree", timeout: 20_000,
  env: [{"MIX_ENV", "test"}], output_dir: "/tmp/my-agent/logs")
T.tail("/tmp/my-agent/logs/build.log", limit: 50)
```

## Return values

File/search calls return `{:ok, map}` or `{:error, %{kind: atom, message: hint, ...}}`.
`write/2` alone returns `:ok` on success. Errors are values, never intentional raises;
nonzero shell exits are **results**, not errors. You can branch in the same eval.
`sh/2` and `tail/2` return a bare result map, or an error tuple on setup/read failure.
The `text` or `output` is compact, not an unbounded tree of raw file structures.

- **read**: `text`, `bytes`, `start_line`, `end_line`, `total_lines`, `next_offset`,
  `truncated`, `notice`. `offset` is 1-based. `next_offset` is the first line not shown,
  even when bytes (rather than `limit`) stop the page; at EOF it is `total_lines + 1`.
  A trailing newline is not a phantom line. Empty files have 0 lines and allow offset 1.
  Newlines (including CRLF) are preserved. Oversized first requested lines are an explicit
  `:line_too_long` error with size and the necessary `max_bytes`, never silently sliced.
  Offset past EOF gives total length. `notice` is separate from `text` to keep contents exact.
- **edit**: `path`, `replacements`, `tolerant_matches`, `diff`. Every old text must be
  nonempty and occur **exactly once**, including overlapping occurrences. Each replacement
  is matched against the **original file**, not earlier replacements. All must succeed
  and change something; overlapping spans are refused. Validation failures never write.
  Exact match wins; only if absent, trailing whitespace, CRLF/LF, curly quotes and common
  Unicode dashes are normalized for matching. Untouched bytes are preserved; inserted
  newlines adopt CRLF when the original contains CRLF, LF otherwise. Only text is supported
  (UTF-8); use `write` for binary rewrites. Diff uses `-old_line| old` / `+new_line| new`
  and caps at 80 lines / 8,000 bytes, announcing any cut.
  Multi-edit validates before one write; it is not a concurrent-editor lock or transactional
  filesystem API. Do not edit a file another agent owns.
- **ls/find**: `text`, `entries` (only the shown paths), `total_entries`, `truncated`,
  `notice`. Sorted; dotfiles included; directories end in `/`. Empty/missing/wrong-type
  paths are distinguished. A cap notice is included in `text` too.
- **grep**: `text`, `matches` (shown matching lines), `total_matches`, `truncated`,
  `notice`. One matched line is `relative/path:line: text`; context uses
  `relative/path-line- text`. No matches is plain `No matches found` in `text`.
  Context does not count against the match cap but **does** count against byte cap.
  Regex by default; `literal: true`, `ignore_case: true`, `context: 2`, `glob: "*.ex"`.
  Globs with no slash match that filename at any depth; otherwise they are relative to
  the search directory (`**/*_test.exs`, `lib/*.ex`). Explicit positive ripgrep globs
  normally override `.gitignore`; this wrapper instead filters already ignore-aware
  results, so a glob cannot accidentally search ignored build/dependency files.
- **sh**: `status`, `timed_out`, `elapsed_ms`, `output`, `full_output`, `total_bytes`,
  `total_lines`, `start_line`, `end_line`, `truncated`, `notice`. Stdout/stderr combined.
  Keeps the **tail** (unlike `read`), bounded by both bytes and lines; byte-limited first
  line can be partial, announced. Invalid UTF-8 is rendered with `?`, without inflating
  the byte cap. Full raw bytes always saved. `tail(path, opts)` has the same tail metadata
  without command status/time. Total sizes come from streaming, not loading the entire log.
  Whole output files remain until callers remove them; they are not automatically expired.

## Bounds and execution

Defaults intentionally sit below the harness's 50 KB cap:

| Helper | Count cap | Byte cap | Other |
|---|---:|---:|---|
| read | 200 lines | 16,000 | `offset: 1` |
| sh/tail | 200 lines | 16,000 | tail retained |
| ls | 500 entries | 16,000 | sorted |
| find | 1,000 paths | 16,000 | sorted |
| grep | 100 matching lines | 16,000 | 500 chars/line |

All accept positive `limit` and `max_bytes`; grep additionally `line_length`.
Every cut is flagged and supplies a concrete way to request more or refine the search.
Counts/bytes bound the content; the short notice is extra. A deliberately large requested
cap can reach the harness cap, so page rather than inspecting megabytes.

`sh` accepts `cwd` (default `/app`), `env` (System.cmd's list of `{name, value}` pairs),
`timeout` (positive milliseconds, default 60,000; `:infinity` disables it), and
`output_dir` (default `/tmp/seedling-tools`). Artifact names are unique. Shell quoting
helper `quote_arg/1` is available when composing commands; never interpolate an unquoted
path. GNU `timeout` controls the command group, TERM then KILL after 1 second, retaining
printed output. A completion marker distinguishes natural exit 124/137 from a timeout.
Commands that deliberately detach (`setsid`, daemonization) can escape the process group;
this is a shell helper, not a sandbox. An eval has its **own** timeout: don't keep turns
open for long builds. Use `Seedling.Background` for long-lived work instead.

`find` requires `fd` or Debian's `fdfind`; `grep` requires `rg`. Both include hidden files
and respect `.gitignore` (even outside a Git repo), excluding `.git` internals. Missing
binaries return a setup error, not a fake empty result. Debian provisioning:

```sh
apt-get install ripgrep fd-find
```

Search commands spill raw output (returned as `full_output`) and scan it for bounded results. Caps bound **returned
output**, not the amount of filesystem work performed; narrowed paths/globs are cheaper.
Read scans for exact total line count while retaining only the requested page (one long
line can still consume memory). Edit reads the whole file for original-span matching.
