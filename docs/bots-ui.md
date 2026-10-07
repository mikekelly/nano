# Bots consumer interface

`NanoWeb.BotsLive` is the separate consumer messenger; `NanoWeb.BotsLayouts.root/1`
loads Phoenix clients plus only `/bots.css` and `/bots.js`. Router integration is owned
by the Bots parent (`put_root_layout` for `/bots`). Operator layouts/assets are unchanged.

The UI reads `Vega.Bots.snapshot/1`, subscribes only when connected, and refreshes on
`{:vega_bots, event}`. All mutations use the service API; no model/tool/harness timeline
is read. Optional `Application.get_env(:nano, :bots_server)` selects an isolated test
service. UI model defaults are explicit: openai-codex/gpt-6.1-sol, low reasoning,
272000 context, unlimited turns/tokens (0), editable under Advanced settings.

## Interaction

- Search titles, last-message previews and participant names; newest conversations first.
- New chat has a keyboard combobox, removable participant chips, inline creation and
  group composition. Start requires participants. Main bot opens its existing direct
  conversation or creates one. Rename topic does not change participant identity.
- Mobile has chat-list/conversation panes and Back to chats; per-session text drafts are
  preserved. Sending clears text only after durable service acceptance. Failed sends
  retain successfully imported attachment refs for retry; attachments require completion.
- Images use `Vega.Images.import_file/1` and immutable canonical refs. Only strict 64-hex
  image-ref IDs can become `/api/images/:id` URLs; no arbitrary path is displayed. Upload
  limit 3.75 MB, four files, with previews/removal and explicit errors. Images service
  additionally validates MIME/dimensions. Voice input is disabled and explicitly labeled.
- Each message has its author's identity; person right, bot left. Thinking/errors are
  separate live status announcements. Retry reply uses `Vega.Bots.retry/2`. Pending
  requests have explicit correlated answer forms and answered state.

## Security and browser behavior

`Vega.Bots.Markdown.render/1` escapes all untrusted HTML, then emits a constrained
paragraph/list/emphasis/code/link subset. Links are strict absolute http/https with
noopener noreferrer; remote Markdown images remain literal text. No model CSS/JS/HTML
or paths are executed. Image URLs are trusted immutable service refs, not Markdown.

Own JS hooks provide recipient keyboard navigation, Enter/Shift+Enter composer behavior,
near-bottom-only follow with New messages jump, and explicit notification permission.
Permission is never requested on mount. Notifications apply only in a background open
tab, not closed-tab push, and honor persisted enabled/request-only/preview/interval/hour
preferences. Durable localStorage deduplication/rate state fails closed when inaccessible;
Web Locks serialize notification accounting across tabs where available. Without Web
Locks concurrent tabs can race (browser limitation; no server notification ledger).

## Tests and limits

Run `MIX_ENV=test mix test test/nano_web/bots_live_test.exs
 test/vega/bots_markdown_test.exs` in an isolated checkout. Tests start the actual durable
Bots service with unique temp roots and an inert model runtime adapter (no provider calls).
They cover onboarding, filtering/chips/group, durable sends, PubSub authors/Markdown/status,
answer cards, notification preferences, mobile semantic panes, and draft failure retention.
Browser OS notification permission delivery, actual mobile layout and real model compaction
require integration/browser evidence; unit/LiveView success is not such evidence.
