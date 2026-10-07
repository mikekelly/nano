# Vega images

`Vega.Images.view("/tmp/screenshot.png")` inside an agent eval imports an immutable
image and queues it for the model (harness integration uses `take_views/0`).
`import_file/1` and `import_bytes/1` return `{:ok, ref}` without attaching. References
are plain JSON metadata (`type: image_ref`, SHA256 id, MIME, dimensions, byte count).
No base64 belongs in state, bindings, transcripts or timeline logs.

API: `POST /api/images` with JSON `{ "data": "<base64>" }` returns the reference;
`POST /api/users/:name/say` accepts `images: [ref]` beside `to` and `text`.
`GET /api/images/:id` serves verified immutable bytes. Agent dashboard has an image
upload form and timeline previews. The API is the seed's unauthenticated operator
API: image URLs are not access-controlled. Do not put secret pictures on this node.

Images are content-addressed under `<state_dir>/images`; refs do not authorize arbitrary
filesystem paths. Fetch verifies the hash and errors on missing/corrupt data. PNG,
JPEG, GIF and WebP headers supply the MIME and dimensions, independent of filename.
Maximum 3,750,000 binary bytes (5 MB base64), 2,000 pixels per side, positive dimensions;
these conservative limits also hold after a transcript grows beyond 20 pictures.
Adapters accept at most 20 images per message. Image headers are inspected; this is not
a full image decoder or malware scanner. Images are retained indefinitely: garbage
collection is intentionally absent while persisted transcripts may refer to them.

Provider catalogs retain `input_modalities`; unknown/fallback entries are text-only,
not guessed vision-capable. Harness saves modalities at start and appends a truthful
vision note. Text-only models get explicit inability notices and metadata, not pixels.
Only request builders hydrate image refs: OpenRouter `image_url` user parts; Codex
`input_image` user parts. Eval images must be appended after all tool outputs, in a
user message, to support every OpenRouter backend. Error bodies redact data URLs.
Estimation uses 4,800 tokens per image; provider usage corrects it on the next response.

Tests: `MIX_ENV=test MIX_BUILD_ROOT=/tmp/vega-images/_build mix test` in this worktree
(the project makes test builds checkout-local). Tests use run-unique temp state dirs.

## Migration and verification

Saved states without `input_modalities_version: 1` look up the provider catalog once
on upgrade, record the answer with version provenance, and re-render the prompt
without resetting history. This includes interim deployments that wrote a text-only
placeholder before modality-aware catalog caches existed. If verification is unavailable
they record text-only conservatively; start a new agent once the catalog works to acquire
vision. Versioned modalities never re-fetch even through catalog outages/restarts.
Model-list cache keys include a schema marker so
an in-memory pre-image catalog does not disable vision for fresh agents after reload.
Active model calls finish with their existing request; no transcript/tool exchange is
rewritten to inject images mid-flight.

Full suite: 264 passing tests after migration, concurrent-store corruption tests, real
LiveView file-upload -> vision wire -> timeline preview, API, eval, and Codex-format tests.
Real isolated Codex test (2026-10-07, gpt-6.1-sol, catalog text+image): a generated
192x128 PNG had colored backgrounds and bitmap digits. The input question did not
contain the colors or number. Returned: "The left is red, the right is blue, and the
central panel shows 47." Reported usage 70 prompt / 22 completion (image accounted
by backend); raw image 733B, immutable metadata148B, estimator4800 tokens.
`scripts/vega/vision_smoke.exs` reproduces the real test using a private temporary credential
copy removed in `after`; invoke explicitly via `mix run --no-start`, not ExUnit.

Live harness confirmation (2026-10-07) after parent-approved reload:
- Fresh `openai-codex/gpt-6.1-sol` agent, catalog modalities recorded text+image.
- Agent called eval `Vega.Images.view` on randomly-named generated PNG; tool log kept
  ref only; after image user-message it answered "The central panel shows 47, with
  red on the left and blue on the right."
- Actual HTTP upload `/api/images` and user `/say` sent a **different** image depicting
  73. The same agent answered "The central panel shows 73, with red on the left and
  blue on the right." Neither filename nor question disclosed the numbers/colors.
- Three real calls, reported prompt/completion 342/41, 522/22, 757/22. Saved state and
  logs checked for data URLs: none; operator timeline has both immutable image refs.
- Disposable probe agent/user stopped; source PNG removed. Content-addressed image
  files/log evidence retained as normal (no dangling persisted transcript cleanup).
