# Real subscription smoke results (2026-10-08)

These were actual Codex backend model requests on the connected ChatGPT subscription,
not scripted HTTP fakes, and did spend provider tokens. Both isolated test agents were
finite-budget children. No model keys, base URLs, node settings or sibling processes were
changed; no test changed its state to manufacture a threshold crossing. Original JSONL
records remain under `/data/logs` after test agents were stopped.

## Automatic threshold crossing

Agent `orion-compaction-live-389`, id `orion-compaction-live-389-824d71`, model
`openai-codex/gpt-6.1-sol`, reasoning low, pid `#PID<0.5903.0>` throughout; zero restarts.
Limits: 35 turns / 250,000 summed tokens / 20,000 context tokens.

1. Actual agent eval set `sentinel = 73`, returned `73`, then replied `READY`.
2. Neutral SHA-256 padding messages requested only `ACK`, preserving that commitment.
   Provider-measured conversation totals progressed 353 → 4,793 → 9,194 → 13,600.
3. The next request estimate crossed the 15,000-token trigger automatically. Harness
   `compaction_started` seq 23 retained 3 messages and summarized 7; checkpoint seq 24
   used 9,107 prompt / 489 completion tokens and recomputed the retained context estimate
   as 5,600. Its structured summary preserved the sentinel commitment.
4. Same pid/mailbox resumed with `ACK` without any operator unhalt/restart. A subsequent
   verification asked to evaluate the **existing** binding, explicitly not reassign it:
   tool result seq 32 was `73`, final model response seq 34 was `73`.
5. Final idle state: no halt, one compaction, zero restarts, 8 normal turns, 66,984 total
   tokens including the summary call, current provider context 9,750.

Full record: `/data/logs/orion-compaction-live-389-824d71.jsonl`.

Reproduce explicitly (spends tokens, never included in ExUnit):

```elixir
Code.eval_string(File.read!("priv/smoke/compaction.exs"), confirm_spend: true, notify: me)
# Returns background task/name/report path. Later sends {:compaction_smoke, path, report}.
```

The script uses the same finite budget, real eval binding, padding and post-checkpoint
verification; it cleans up only its own unique agent, preserving the provider log.

## Actual visual understanding

Agent `orion-images-live-17827`, model `openai-codex/gpt-6.1-sol`, reasoning low, pid
`#PID<0.9821.0>` throughout, zero restarts. Limits: 12 turns / 60,000 tokens / 20,000
context. Fresh model metadata was `["text", "image"]`, safely refreshed when the old
provider cache lacked `input_modalities`.

- External attachment: a real 64×64 PNG of solid red pixels, delivered with
  `Nano.Ops.send_image`. The request carried no filename/color hint. Model response seq 5:
  **“A solid bright red square fills the image against no visible contrasting background.”**
  Usage: 309 prompt / 18 completion.
- Eval view: request named a neutral `scene2.png` path and instructed the agent to call
  `Nano.Images.view`, not read bytes. Tool call produced a 64×64 immutable reference
  (sha256 `b541918ce3a55b1cb8e509bd9cd05d2075db06c46d7389bdc980355e1a733cad`).
  Actual pixels were a blue triangle on white. Model response seq 14:
  **“A solid blue triangle pointing upward sits centered on a white background.”**
  Usage: 569 prompt / 17 completion after the image-view tool result.
- Final idle state: no halt, zero restarts, 3 normal turns, 1,374 total tokens, current
  context 586. Stored transcript/log references contained no base64 image bytes.

Full record: `/data/logs/orion-images-live-17827-1b2e9b.jsonl`.

Separate HTTP fake-provider tests cover exact OpenRouter `image_url` and Codex
`input_image` wires, API upload/immutable serving, actual LiveView upload and pictures in
both timelines, explicit nonvisual warnings, decoder failures, JPEG/static GIF acceptance
and animated GIF refusal. Live OpenRouter vision was not tested: no provider spend was
needed to prove its wire format, and these results do not claim actual upstream coverage.

## Real coordinator recovery: serialized history larger than a single summary input

A later production run exposed an additional long-life failure not covered by the initial
small-window smoke: coordinator `orion` reached provider context **256,133 / 272,000**,
then halted at 14:35:36 because its serialized older prefix was **538,414 bytes**, above
the conservative single-call guard of **513,904 bytes**. There were 601 older messages
and 6 recent messages; the full JSON transcript was approximately 1.57 MB. This was a real
failure, not a manufactured threshold. The original history stayed saved and the agent
was idle with no task in flight.

Fixes `df1f7af` and `3a5900f` add bounded chronological update passes, without weakening
that input guard or silently dropping history. Prior checkpoints have reserved space in
every later input. Oversized individual records use UTF-8-safe annotated continuations;
there is a 64-pass ceiling and up to three transient attempts per pass. The actual parent
prefix was independently replayed into two chunks: **459,953 and 78,460 bytes**. Fake HTTP
regressions prove checkpoint carry, per-call bounds, summed usage/cost, oversized Unicode
record preservation, and atomic retention of the original transcript on a later failure.

Emergency recovery loaded **only the builder-owned new `Nano.Compaction` module** from its
committed worktree, then called `Nano.Ops.unhalt("orion")`. No `NanoAgent`, seeded provider,
or other owner's module was loaded, and no history/bindings/mailbox were manually replaced.
The coordinator could not answer the permission request while halted; a read-only reviewer
confirmed quiescence and reviewed the owned-module scope/source before activation.

Actual checkpoint completion: **2026-10-08T15:17:03.304Z**, seq **1455**, full record
`/data/logs/orion-b0dc85.jsonl`. Both real Codex calls completed, totaling **154,311 prompt
+ 13,315 completion tokens**. The final structured summary was **29,316 bytes**, and the
recomputed conservative context estimate was **28,728**. The same pid `#PID<0.4487.0>`
resumed normal model calls; restart count stayed **1** (there was no recovery restart).
Subsequent provider context was around **20,593**, with one compaction and no halt.

The large recovery took approximately seven minutes; its task remained alive waiting for
SSL responses rather than silently stopped. Partial failed-pass costs are exposed in the
new error metadata; `897cb88` adds harness charging of those known counters while preserving
the original transcript and any budget halt. That separate seeded-harness change was
committed/tested and handed to the recovered coordinator for approval, not hot-loaded by
the builder during the emergency recovery.
