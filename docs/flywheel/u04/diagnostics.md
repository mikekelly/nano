# U04 credential diagnostic boundary (repaired attempt)

ChatGPT.Auth, Settings and OpenRouter.Auth retain the same live state maps and durable
JSON formats. Their OTP25+ format_status/1 callback preserves supplied keys, returns []
for log (the native OTP formatter requires a list), and removes other payloads including
login state, settings names, refresh/gen-call envelopes and unexpected future fields.
Only a fixed failure-class allowlist survives. Public call-exit errors no longer inspect
arbitrary exit tuples containing the original request.

## Intentional abnormal failure contract

OTP29 appends the original exception stack AFTER format_status, and proc_lib separately
reports queued messages/dictionary. The sensitive process flag suppresses process_info
payloads at default unlimited depth, but **does not** protect queued messages at finite
kernel error_logger_format_depth: proc_lib directly receives them. A disposable depth20
probe confirmed this leak for all three servers. No sensitive flag is retained and no
node-wide logger filter or mailbox drain is used.

For abnormal termination these servers now exit with
`{:shutdown, {:credential_diagnostic, fixed_class}}`. The GenServer termination report
retains the fixed failure class and the server's handle_call/handle_cast/handle_info MFA,
with arity only and no arguments or arbitrary stack metadata. The shutdown tuple prevents
proc_lib's independent raw crash report. Normal, shutdown and requested shutdown-tuple
exits retain their original semantics.

**This is not behavior-neutral.** Direct monitors and trapping links observe the tagged
shutdown tuple instead of the old exception reason/stack. Nontrapping links still exit on
this tuple. A transient supervisor would not restart a shutdown child. Production
Nano.Application uses the three GenServer default **permanent** child specifications
and only changes their start MFA to start_retrying; permanent restart, its startup retry,
and retained dummy auth/settings files are exercised by the disposable regression driver.
Public callers receive a fixed-class error, not the original reason/envelope. Existing
credential rotation/revocation/storage and pending-login lifecycle policies are unchanged.

## Verification and restoration

`MIX_ENV=test mix run --no-start test/flywheel/u04/crash_boundary.exs` in exact private roots
captures ordinary actual production-callback crashes with SASL translation visible at
unlimited and finite20 depth. It checks raw events, native OTP formatting (both single
and multiline), tagged monitor exits, permanent restart through production start_retrying,
dummy auth/settings file retention/reload and unchanged normal shutdowns. Existing normal
ExUnit regressions cover status/debug-buffer and actual GenServer termination boundaries.
Explicit privileged raw `:sys.log_to_file` tracing is not a credential sandbox and is not
claimed safe by this unit. No live credential process is crashed or raw status inspected.

Allowed restoration is roll forward with these callbacks and latest coherent JSON files.
No durable migration is needed: writers and state shapes are unchanged. Callback deployment
is state-compatible but changes the intentional failure contract above; parent alone loads
and verifies it. Restoring old diagnostics is not a safe security fallback. Never discard
newer credential invalidations, pending evidence, lifecycle tombstones or graph generations.
