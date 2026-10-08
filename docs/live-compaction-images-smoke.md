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
