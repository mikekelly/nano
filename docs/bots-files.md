# Produced files in bot messages

`Vega.Bots.attach_file(path)` imports a regular file up to 8MB into owned immutable
SHA256 storage under the bots root. Returns canonical string-key ref; use
`Vega.Bots.post(session_id, bot_id, "Here is the report", files: [ref])`.
Messages accept at most four validated refs. Arbitrary paths/URLs cannot be posted as
refs. `GET /bots/files/:id` verifies hash and always downloads application/octet-stream
with attachment Content-Disposition, nosniff and CSP sandbox/default-src none. A bot's
HTML file never executes on this origin. Filename is bounded/sanitized and URI-encoded
in response headers. Files are retained indefinitely while chats may refer to them.
No garbage collection/authentication is implied by immutable IDs.

Tests cover path traversal IDs, metadata canonicalization/header characters, changed
source file preserving previous bytes and digest corruption. Actual runtime fake-provider
test covers eval posts, independent pair agents retrieving identity memories,
automatic harness compaction across threshold, continuation and agent restart.
