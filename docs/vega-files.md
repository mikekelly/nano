# Vega file and shell foundations

`Vega.Files` returns values rather than raising normal IO errors. All output limits
are below the harness cap. Examples:

```elixir
{:ok, page} = Vega.Files.read("lib/example.ex", offset: 1, limit: 200, max_bytes: 16_000)
# page.text, page.next (nil at EOF), page.total (known only at EOF), page.truncated
Vega.Files.read("lib/example.ex", offset: page.next)
Vega.Files.edit("lib/example.ex", [{"unique old", "new"}, {"other old", "other new"}])
Vega.Files.sh("mix test", cwd: "/tmp/my-worktree", timeout: 60_000,
  env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", "/tmp/my-worktree/_build"}])
```

Read streams bounded 8KB chunks, preserving whole physical lines and original line
endings. No full-file read or line-list allocation. Offset is 1-based. It emits at
most limit lines/max_bytes bytes, never silently cutting or advancing past content.
A line exceeding the cap is an explicit `{:line_exceeds_max_bytes, line_number}`
error: raise max_bytes (or use an external byte reader). If it follows a valid page,
that page is returned with next pointing at the long line. An offset past EOF is an
error giving total physical line count. Empty files are a valid empty first page;
terminal newlines are not phantom extra lines. UTF-8 and CRLF bytes are preserved.

Exact edits require each old string to occur exactly once in the original file;
overlapping occurrences count too. Empty/no-op/overlapping replacements are refused.
All replacements are validated before any write. No fuzzy match or line-ending
normalization. `:ok` on success; helpful uniqueness/not-found errors otherwise.
There is no cross-process file lock, tolerant matching or returned diff. Writers
must coordinate ownership; this helper is not a compare-and-swap filesystem.

Shell uses GNU timeout with 2s kill-after, redirects combined stdout/stderr to a
unique output file, and seeks only the last max_bytes (default 16KB), keeping the
last limit (default 100) lines. The full file remains at result.path; `tail(path,
max_bytes: ..., limit: ...)` can retrieve a different tail. Bytes are bounded even
for multi-megabyte single lines. A byte-bound tail may start mid-line or mid-UTF8;
output is binary and callers requiring valid text must handle that boundary.
Result includes status, timed_out, duration_ms, bytes, truncated, output and a bounded
diagnostic (shell launch/syntax errors). No full-output read/allocation in BEAM.
Timeout preserves earlier output. GNU status 124/137 indicates timeout/kill; a
command deliberately exiting those same statuses cannot be distinguished. Full
spill files are caller-owned and should be removed when no longer needed.

`write` creates parent directories. `ls` sorts and caps 500 paths; `find` caps 1000;
`grep` streams matches and caps 100 with 500 characters per matching line. These
simple list/search helpers do **not** yet implement gitignore filtering, regex,
context, directory markers or exhaustive truncation metadata. `find` still uses
Path.wildcard's complete discovery before capping. Reported scope is bounded paging,
shell tail/timeout and exact-edit improvements, not full parity with pi's tools.
