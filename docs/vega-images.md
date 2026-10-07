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
Adapters accept at most 20 images per message. Header metadata is checked first, then a
bounded Pillow decoder verifies and loads the first frame before admission. Only static
images are accepted; animation is rejected without iterating/decoding all frames. The
helper is a decoder, not a malware scanner. Images are retained indefinitely: garbage
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

## Strict decoder dependency and bounds

Fresh Debian nodes need `apt-get update && apt-get install -y python3 python3-pil coreutils`
(include these packages in deployment Docker builds). Decoder source is `priv/vega/verify_image.py`,
invoked with `/usr/bin/python3 -I -B`, not the possibly unrelated `/usr/local/bin/python3`.
A deployment may set application env `:nano, :image_decoder_python` to an equivalent
Python executable with Pillow; this is not a secret or a node dashboard setting.
If Python, Pillow, helper, or GNU `timeout` is unavailable, admission fails closed with
an explicit installation error. There is deliberately no header-only bypass.

The decoder runs for at most 5 seconds, with SIGKILL on deadline, 3 CPU seconds,
256 MiB address-space, no file writes/core dumps. Raw bytes travel only in a unique
0600 file inside a private0700 `.validate-*` directory under the image store; the
subprocess argv contains only its path, never base64. `after` cleanup runs on failure,
success, and timeout. The real helper also unlinks the raw file immediately after a
bounded read, before decoding from memory (mitigating caller-death leftovers). It rejects invalid pixels, truncated compression, CRC failures
and animations. It never iterates an animation's frame sequence; first-frame decode
only occurs after the static-image check. Python/native codec subprocess bounds
protect the VM, but are not an OS sandbox against intentionally malicious native code.

Verified/rejected hashes are cached on disk with decoder-rule schema `v2`; each fetch
still checks the immutable-byte SHA256. Legacy header-only references are validated
at the provider edge on first use. Invalid/missing images become explicit user text
(`Image attachment <id> unavailable ... no contents were provided; do not guess`),
not bad image parts and not a permanently failing model request. The stored transcript
and metadata reference stay unchanged. Decoder unavailable/timeouts are not cached as
content rejection, so installing/fixing the decoder allows a later attempt to succeed.
An invalid-content cache marker contains no image data, and an already verified image
can still be used when the decoder is temporarily unavailable.

Strict-admission tests use genuine static PNG/JPEG/GIF/WebP fixtures and native Elixir
PNG fixture generation. Header-valid but truncated images are rejected before an image
file/reference is persisted; animated GIF rejected; bad legacy refs hydrate to explicit
text; missing dependency/stalled subprocess fail closed and leave no temp bytes;
concurrent imports and verified cache reuse are covered. No real malformed-provider
request was made (would waste budget and poison a growing transcript).

## Composing existing references

`Vega.Images.view(ref)` validates/canonicalizes an existing image reference and queues
it exactly like `view(path)`, without exporting bytes, base64 or intermediate source
files. For example, `{:ok, %{image: ref}} = Vega.Browser.screenshot(browser);`
`Vega.Images.view(ref)` lets a vision agent see a browser screenshot directly. A wrapper
result map is not a reference: pass its `image` field. Invalid maps/types return errors
and queue nothing. When eval tool calls share a response, all images appear together
in a user message after **all** tool outputs, regardless of path-versus-ref source.
