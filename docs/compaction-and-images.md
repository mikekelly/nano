# Automatic checkpoints and images

Every NanoAgent automatically checkpoints older history when the estimated next request
or latest measured context reaches its window minus a reserve (16,384 tokens, scaled down
for small windows). The original pid, name, mailbox, eval bindings and working files stay
untouched. Summaries use a separate tool-free call to the same model, with up to three
transient-error attempts, and are charged to agent/node token and cost totals, not agent
turns. Recent complete turns are retained verbatim. Existing checkpoints are updated.

Nano.Compaction documents the serializer and split. Tool results are capped at 2,000
characters in the summary input. Operators can follow `compaction_started`,
`compaction_completed` (including summary/model/full-log path) and `compaction_failed`
entries. Agents receive an explicit harness-authored checkpoint stating what happened,
which model did it, and where the full record is. FrontOfMind reminder hooks run before
request sizing and immediately after compaction when that optional capability is loaded.

A single oversized turn cannot safely be compacted: its current user request and tool
pairs must remain intact. The unchanged final pre-call check still halts rather than send
an unsafe request. Failed/oversized summaries are explicitly logged and halt `:context`,
not silently retried forever. An operator can unhalt after fixing limits/provider failures.

## Images

```elixir
# Eval (image is delivered after all the response's tool results)
Nano.Images.view("/tmp/screenshot.png")

# Operator
Nano.Ops.send_image("alice", "/tmp/photo.jpg", "Describe this")
{:ok, ref} = Nano.Ops.upload_image("alice", base64, "Describe this")
{:ok, bytes, mime} = Nano.Ops.image(ref["id"])
```

PNG, JPEG and GIF are sniffed from bytes. Limits are 3,750,000 raw bytes (5 MB base64),
1–2,000 pixels per side: the stricter dimension cap deliberately also covers histories
containing over 20 images. Unsupported/malformed headers, oversized uploads and invalid
references are refused before delivery. WebP is not yet supported. There is no image
transcoding and no automatic deletion policy.

Images are snapshotted by SHA-256 under `<state_dir>/images` (`:image_dir` app env can
override), atomically published and read-only. Transcripts, saved state and logs contain
only metadata references, never base64. Every request hydrates references and verifies the
hash; missing/changed files cause an explicit model refusal instead of silently changing
the cached prefix. Image cost estimates use 4,800 tokens, corrected by provider usage.

Model input modalities are persisted at start. Unknown modalities are conservatively
text-only; known Codex fallback entries support text and images. Text-only models get an
explicit warning on every attachment and a truthful system prompt, while operators still
receive the image reference in the timeline. OpenRouter user content uses `image_url`;
Codex translates it to `input_image`. Eval views are user messages after tool results,
portable across both providers. `images_received` log entries expose the same immutable
references for authenticated API/dashboard display. Route/UI glue is integrated separately.

## Tests

`MIX_ENV=test mix test test/nano/compaction_test.exs test/nano/images_test.exs` exercises
real GenServers and HTTP fake providers, including threshold crossing, live queued
messages, binding/identity preservation, continuation, summary failure, wire hydration,
nonvisual warnings, immutable snapshots and validation. These tests do not spend tokens.
A live subscription threshold/vision smoke test is separately reported in the run notes.
