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
leaking authorization or service details. Key defaults to TYPESAFE_API_KEY environment
variable. No node settings are added or changed. `model:` overrides model name;
`req_options:` is a trusted-callers-only Req override for tests/custom transport (can
redirect credentials, so do not accept this option from untrusted input).

## Evidence and limits (2026-10-07)

Fetched and read the real introduction, quickstart and documentation index at
https://docs.typesafe.ai/introduction.md and
https://docs.typesafe.ai/introduction/quickstart.md. Implemented the documented wire format.
No TYPESAFE_API_KEY was available in this node's registered settings or environment.
**No real inference request ran; live service compatibility remains unverified.** Six
scripted Req HTTP fixture tests prove payload/authorization, noul/choice/score response
validation, missing credentials and error handling; fixture model names explicitly say
not-real. Goals/memory never call the decision service automatically. Lexical memory
retrieval works offline and is not represented as semantic retrieval.
