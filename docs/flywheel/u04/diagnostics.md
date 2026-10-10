# U04 credential diagnostic boundary

ChatGPT.Auth, Settings and OpenRouter.Auth retain the same live state and durable JSON
formats. Their OTP 25+ `format_status/1` callback keeps the supplied keys but removes all
payloads, including login state, settings names, refresh/gen-call envelopes and debug logs.
Only a fixed failure-class allowlist survives. Public API call exits no longer inspect
arbitrary exit tuples (which include the original request).

OTP 29's gen_server appends the original exception stack after format_status returns.
A Settings `:maps.put/3` failure demonstrably included dummy credential arguments there.
The termination callbacks therefore replace abnormal exits with a fixed class and empty
stack using `:erlang.raise/3`; normal and shutdown exits retain normal behavior. This
intentionally sacrifices raw stack diagnostics on these credential-holding servers.
No credential revocation, refresh policy, storage, or pending-login lifecycle is changed.

Restoration: roll forward with these callbacks and the latest coherent settings/token files.
No durable migration/rehearsal is applicable: neither writers nor state shapes changed.
Restoring old diagnostic code is not a safe security fallback, even though JSON remains
readable. Never replace newer credential or graph authority files with older checkpoints.
Parent alone deploys compatible callbacks, verifies with isolated dummy fixtures and
announces closure; this artifact is not deployment evidence.

Regression entry points: Nano.AuthDiagnosticsTest invokes all three production callbacks,
real anonymous GenServers, :sys.get_status, :sys.log, production handle_call failures,
and :sys.terminate with queued refresh/gen-call messages. It does not inspect live status.
