# Seedling capability index

Branch `seedling/orion-harness`; never merged into main. Modules are callable from eval.

## Files and shell

`Seedling.Tools` — Bounded file paging/search/listing, exact multi-edits with diff, safe shell timeout/tail/full spill. read/sh retain compact metadata. See docs/tools.md; rg/fd-find required and installed by Dockerfile.

```elixir
Seedling.Tools.read("/app/NOTES.md"); Seedling.Tools.sh("git status --short")
```

## Background jobs

`Seedling.Background` — Completion event %{background: id,status: code,reason: atom,output: path,bytes: n}. tail(path), cancel(pid), info(pid). Survives agent restart, not node restart. tail(path) returns {:ok,page_map} with exact backward paging; result(owner,id) recovers durable status. See docs/background.md for containment and unacknowledged-send limits.

```elixir
Seedling.Background.start("MIX_ENV=test mix test", owner: "orion", timeout: 120000)
```

## Delegation

`Seedling.Delegation` — Composed prompts, hashed pre-reading, explicit worktree revision, optional MCP. Durable completion/failure/restart events by parent name. report/2, result/1, tell/2; docs/seedling/delegation.md.

```elixir
Seedling.Delegation.subagent("scout", model: "openai-codex/gpt-6.1-sol", reasoning: "high", max_turns: 40, max_tokens: 200000, max_context: 100000, prompt: "Investigate", pre: ["/app/NOTES.md"], message: "Begin")
```

## Automatic checkpoints

`Nano.Compaction` — Harness automatically summarizes older history before context exhaustion and within long tool loops; preserves pid/mailbox/bindings, paired recent turns and durable logs. Structured checkpoint plus deterministic files list. docs/compaction-and-images.md; explicit failure/retry, pre-call safety remains.

```elixir
NanoAgent.info("orion")
```

## Goals

`Seedling.Goals` — Durable goal trees with why, parent IDs and open/active/blocked/done/cancelled status. Child completion checked. Bobbing optional via configure/2. Dashboard integration forthcoming; real orchestration goals persisted for orion.

```elixir
Seedling.Goals.create(me, "Deliver capability", "Why it matters"); Seedling.Goals.review(me)
```

## Memory

`Seedling.Memory` — Durable per-bot graph with links/provenance, bounded retrieval, Jev reranking; labelled lexical fallback if decision service unavailable.

```elixir
Seedling.Memory.remember("my-bot", "preference", "Prefers quiet hotels"); Seedling.Memory.recall("my-bot", "hotel")
```

## Front of mind (experimental)

`Seedling.FrontOfMind` — At most 1000 characters, durable set/replace/clear. Automatic bobbing hooks integrated at every model request and after compaction; own note visibly re-shown on real orion. Do not infer efficacy from implementation; controlled comparison required.

```elixir
Seedling.FrontOfMind.set(me, "Keep the constraint in view"); Seedling.FrontOfMind.configure(me, threshold: 8000, drift: true)
```

## Typed decisions

`Seedling.Decision` — Typesafe Jev typed noul/choice/score judgments; returns probabilities/errors as values. Supplied TYPESAFE_API_KEY live validated against jev-1.13.0; never print credentials.

```elixir
Seedling.Decision.evaluate("Recent activity", %{"drift" => Seedling.Decision.noul("Has activity drifted from the goal?")})
```

## Images

`Nano.Images` — Immutable sniffed and fully decoded single-frame PNG/JPEG/GIF refs, bounded bytes/dimensions. Fresh vision agents receive actual pixels on provider wire; text-only agents get explicit warning. API POST /api/agents/:name/images {base64,text}, GET /api/images/:id and dashboard upload/timeline. Hot source integration done, router live reload forthcoming. docs/compaction-and-images.md.

```elixir
Nano.Images.view("/tmp/screenshot.png")
```

## Web reading

`Seedling.Web` — HTTP-first readable text, Lightpanda JS fallback, 1h/100-entry disk cache. read(id,offset:next), cite(id,offset:,limit:). Bounded Unicode pages; PDFs/video/repository checkout explicitly unsupported. docs/web-search.md.

```elixir
Seedling.Web.fetch("https://elixir-lang.org", mode: :auto, limit: 2000)
```

## Search and async research

`Seedling.Search` — Exa compact highlights/ids, contents/answer citations, current /agent/runs research completion events by stable agent name. research_read/watch/cancel; explicit key errors, no scraping. Actual grounded structured research cost $0.012 validated. After node restart call watch(remote_id). docs/web-search.md.

```elixir
Seedling.Search.search("Erlang OTP documentation"); Seedling.Search.research("Explain BEAM mailboxes", effort: "minimal", notify: me)
```

## Browser

`Seedling.Browser` — Lightpanda JS DOM/fill/click and owned loopback CDP, stop(session); fetch_async returns Background job, read_background(event) pages render. Actual JS/forms/CDP and agent restart lifecycle tested. docs/web-search.md.

```elixir
Seedling.Browser.run(url, [{:fill, "#q", "text"}, {:click, "#go"}]); Seedling.Browser.serve()
```
