# Optional Jev decisions

`Vega.Decision.evaluate(state, questions, api_key: key)` calls the real documented
`POST https://api.typesafe.ai/v1/systemone` API with `jev-latest` by default.
Questions use **string keys**, including named IDs. State can be a string or JSON data.

```elixir
Vega.Decision.evaluate(%{message: "Please help today"}, %{
  "urgent" => %{"type" => "noul", "instructions" => "Does this message express urgency?"}
}, api_key: System.get_env("TYPESAFE_API_KEY"))
```

Successful return: `{:ok, %{"answers" => ..., "model" => ..., "usage" => ...}}`.
Answers are checked against question IDs and types; noul must be a 0..1 probability,
choice must be an offered option, score must fit its criterion-index range; choice/score
include 0..1 confidence and normalized distributions over all offered criteria. The
service's probabilities remain visible; this module makes no routing decisions.

Supports documented `choice` criteria maps and `score` criteria lists as well as noul.
Up to 64 questions and a 200 KB JSON request. Requests do not automatically retry (avoid
surprise spend). Timeout defaults 15 s, override `timeout:` milliseconds. Errors:
missing_api_key, invalid_request, invalid_response, transport_error, {:http_status, n}.
HTTP error bodies and transport exception messages are deliberately not exposed, to avoid
leaking authorization or service details. Key defaults to the live `Nano.Settings.get("TYPESAFE_API_KEY")` string-name setting,
then the TYPESAFE_API_KEY environment variable. No node settings are added or changed. `model:` overrides model name;
`req_options:` is a trusted-callers-only Req override for tests/custom transport (can
redirect credentials, so do not accept this option from untrusted input).

## Evidence and limits (2026-10-07)

Fetched and read the real introduction, quickstart and documentation index at
https://docs.typesafe.ai/introduction.md and
https://docs.typesafe.ai/introduction/quickstart.md. Implemented the documented wire format.
The first credential check incorrectly inspected only registered atom settings and the
environment; operator correction identified the **string-name** live setting. Read
`Nano.Settings.get("TYPESAFE_API_KEY")` on the live node without logging its value.
Two approved live requests through the owned adapter succeeded with **jev-1.13.0**:

- Noul urgency: 0.97; usage 286 input / 20 output tokens.
- Choice team: technical, confidence 1.0, probabilities technical 1.0 / billing 0.0.
  Score severity: 1.0, confidence 1.0, probabilities 0: 0.0 / 1: 1.0.
  Combined request usage 376 input / 44 output tokens.

Loaded only owned Vega.Decision into the running node with parent approval. No keys
printed, subprocess-serialized or committed; no settings modified. Six scripted Req
HTTP tests run offline and prove deterministic error/payload handling; they are not
claimed as inference tests. Real requests are manual smoke checks, not default tests,
so rerunning the suite never spends. Goals/memory never call Jev automatically. Lexical
memory retrieval works offline and is not represented as semantic retrieval.
