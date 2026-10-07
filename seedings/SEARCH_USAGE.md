# Search and research from eval

`Seedling.Search` implements `seedings/search.md` using Exa. `EXA_API_KEY` must be
present; missing keys, HTTP errors (including 401/429), invalid arguments and transport
failures return `{:error, %{kind: atom, status: optional_integer}}`, not exceptions.
Error bodies/exception messages are deliberately not echoed, to avoid leaking credentials.

## Find, read, cite

```elixir
{:ok, found} = Seedling.Search.search("Elixir programming language official docs")
# found["results"]: title, url, id, highlights, author, publishedDate; no full text
urls = Enum.map(found["results"], & &1["url"])
{:ok, pages} = Seedling.Search.contents(Enum.take(urls, 2))
{:ok, answer} = Seedling.Search.answer("What is the capital of France?")
# answer["answer"] contains numbered references; answer["citations"] contains URLs
```

Cite the actual returned URLs; verify the page supports the claim. Search defaults to
five results, highlights only, with a provider-requested 1,000-character highlight budget.
`num_results: 1..20`, `type: "auto"` (default), and `params: %{...}` add supported Exa
filters (e.g. `"includeDomains"`). Reserved query/count/type/contents fields cannot be
overridden via params, so search cannot accidentally request full text.
Contents accepts 1–20 URLs/ids, requests at most 12,000 characters of text per page.
All compact responses share a 20,000-byte string-content budget and at most 100 entries
per nested collection. `_truncated: true` indicates clipping; JSON structure/keys add
some overhead. Results additionally divide a 19,000-byte budget evenly across pages,
processing citation metadata before highlights/text so an oversized page cannot starve
later pages' ids and URLs. Request fewer pages or results if clipped. Research completion retains
full output on disk and only sends bounded data through the mailbox.
`research_status/2` is an explicit full provider response fetch, not a compact result.

## Background structured research

Current Exa docs call this **Exa Agent**; the supported endpoint is `/agent/runs`,
not the old research endpoint. This code follows the current API.

```elixir
Seedling.Search.research("What is the capital of France? Cite a source.",
  notify: "my-agent", # use your actual registered agent name, not eval's self()
  schema: %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}},
            "required" => ["answer"]})
# {:ok, %{id: provider_id, worker: pid, path: durable_json_path}}
# Later event:
# {:search_research_done, provider_id,
#   {:ok, %{id: provider_id, path: durable_json_path, data: bounded_provider_run}}}
# Or {:search_research_done, provider_id, {:error, error_map}}
```

`data["output"]["structured"]` is the schema-shaped answer. `output.grounding` carries
field-specific citations/confidence; `output.text` is a narrative. A schema is sent to
Exa, not locally revalidated. Always examine `status`, `stopReason`, and grounding;
completed does not necessarily mean every requested claim was found.

Default effort is **minimal**, documented fixed cost $0.012/request as of this run.
Options `effort: "low" | "medium" | "high" | "xhigh" | "auto" | "ultra"` affect spending.
Auto/ultra can use `budget: %{"maxCostDollars" => 1}` (provider accepts $1–$100);
fixed efforts do not accept budget. No implicit live research occurs in tests.
Creation happens synchronously (one HTTP call); subsequent polling is independent of
the eval task. Required `notify` accepts a pid or registered NanoAgent name. Prefer a
name, which survives agent restart. Named delivery retries for 60 seconds; mailbox
delivery has **no durable acknowledgement**. Pid recipients are not restart-safe.

Options: `poll_interval: 4000`, `poll_timeout: 600_000`, `timeout: 30_000` per HTTP call,
`state_dir: "/data/seedling/search"`. 429 and transient 5xx responses are retried while
polling; submission is never retried automatically to avoid duplicate charged runs.
Polling deadline is checked between calls, so a slow HTTP call can exceed it by its
request timeout. A poll timeout does **not** cancel the charged provider run.

```elixir
Seedling.Search.research_status(id) # full provider state
Seedling.Search.cancel_research(id) # POST provider cancel, returns provider state
Seedling.Search.resume(id, notify: "my-agent") # resume polling without resubmission
```

Run identity/recipient description is written before starting the worker. Completion
(full run or error) atomically replaces that JSON file; no API key is persisted. Workers
survive eval/agent exit, but **not node/container restart**. After restart manually resume
known pending ids; no application startup hook was added. Duplicate resume calls can
produce duplicate notifications; treat the provider id as the deduplication key. If
local persistence fails after submission, a remote run may still exist (inspect Exa's
run listing); there is no transaction spanning HTTP creation and local disk. Completed
files require operator retention/cleanup. Exa team Zero Data Retention settings may
limit retrieval to ten minutes after completion, so local files are the lasting record.

## Validation and provider references

Provider docs read from the node on 2026-10-07:
- https://exa.ai/docs/llms.txt
- https://exa.ai/docs/reference/search.md
- https://exa.ai/docs/reference/answer.md
- https://exa.ai/docs/exa-spec.yaml (including contents, Agent run schemas/statuses/cancel)
- https://exa.ai/docs/agent/quickstart.md

Fake tests: `MIX_ENV=test mix test test/seedling_search_test.exs`.
`transport: fn req_options -> {:ok, %{status: integer, body: map}} end` injects a fake
without touching global configuration. Additional transport options: `api_key`,
`base_url` (trusted endpoint only; receives your key), and per-call `timeout`.
Production transport is Req with retries and redirects disabled. Do not print a key.

Live smoke explicitly spent provider credits: search returned the official Elixir site
and docs (reported $0.007); contents fetched 6,205 bytes from elixir-lang.org; answer
returned Paris with Britannica/Wikipedia citations ($0.005); minimal-effort Agent run
completed asynchronously in about six seconds, sent a later mailbox event, returned
schema-shaped Paris with Britannica grounding, and persisted it ($0.012). No UI/model
behavior was claimed tested by this smoke. Library use is explicit: it does not rewrite
agent prompts or force agents automatically to search.
