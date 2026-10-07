# Credential requests without credential chat history

`Vega.Bots.request_setting(bot_id, "MY_SERVICE_KEY", "Please configure my service",
requester: "stable-agent-name", session_id: session_id)` creates an explicit setting
request. Allowed names are registered `Nano.Settings.specs()` entries of type secret
(currently openrouter_api_key) or uppercase custom environment-style names. Registered
nonsecret limits/URLs/prompt-file settings cannot be disguised as credential requests.
No secret is supplied when making a request. The human sees the exact setting name.

Use the consumer password control, **not general chat** and not an agent eval containing
a real value. It posts native JSON `{password: ...}` directly to
`POST /bots/requests/:id/setting` with same-origin credentials and CSRF header. The
control must have no LiveView change/submit binding; raw value never enters LiveView,
BotServer state/mailbox, messages, memory, requester event or model transcript. JavaScript
clears its input on success, failure and teardown; it never logs or echoes the value.
Route log:false suppresses Phoenix action parameter logging; the parameter name password
is also in Phoenix's default filtered list. Parent config should explicitly include
password and secret_value in `config :phoenix, :filter_parameters` for defense-in-depth.

The caller/HTTP process passes the value directly to Nano.Ops.put_setting. Nano.Settings
atomically stores settings mode0600 and masks its status/crash state. Only after that
succeeds does the helper send BotServer the request ID and canonical setting name.
The service persists an answered card/chat saying the credential was saved, with only
`%{"setting_key" => key, "set" => true}`. By-name relay retains the existing correlation
and ack protocol: `{:vega_human_answer, request_id, metadata}`. The requester can retrieve
and USE the setting inside eval, but must return only safe result metadata: never return,
print or put the value into chat, goals, memory or model context. All agents already have
privileged read access to settings on this node; this is not a security sandbox.

Generic `answer_request` checks kind BEFORE passing an answer to BotServer and rejects
credential requests with use_setting_form. Normal choice answers remain unchanged.
Credential completion is idempotent: repeated replies to an answered request don't
replace the stored setting. Per-request lock serializes racing completion attempts.

## Honest atomicity and security limits

Settings and bots state are different atomic files, not one transaction. A failure
between setting save and request acknowledgement leaves the setting saved but request
pending; confirmation error is generic and the password input still clears. Operator
can repair state and person can re-enter/retry. No fictitious cross-file transaction
is claimed. Metadata describes successful setup at that moment, not a guarantee an
operator won't later delete/change the setting. Node remains single-user unauthenticated
and root-privileged; this avoids accidental credential history, not malicious agents.

## Evidence

Tests in an ISOLATED external test VM use a fake custom credential only. They verify
key allowlist/nonsecret rejection, protected native JSON flow, no raw value in response,
controller params/debug capture, bots disk/chat, actual named requester model wire/saved
transcript/harness log, idempotence and ack; only settings.json contains it and has0600.
No live settings or actual secret values were changed/read into this agent context.
Backend/controller focused tests2 plus existing service9 pass (11 total). Frontend
password-control/JS tests and final full suite follow the frontend merge.
