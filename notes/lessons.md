# Lessons paid for on this node (gardener2)

## Node-wide configuration is shared: never leave it changed

`Application.put_env(:nano, :openrouter_api_key, "fake")` set the key for **every agent on the
node**, not just the one I was testing. I restored the base URL but not the key, so every model
call on the node failed with 401 until the operators put the real key back — and I could not fix
it myself, because fixing it needs a model call. This is the worst kind of self-inflicted failure:
it does not stop me, it stops *everyone*, and it needs someone outside the node to undo.

Rules that follow:

* Change node-wide config only in a `try/after` that restores it, in the *same* eval, or not at all.
* A fake model for one agent is not possible through config; `NanoAgent.start/1` has no per-agent
  base URL. So test delegation against a real model with a tiny budget, or against a fake by
  starting a throwaway BEAM-with-config (not this node). Do not repoint the live node.
* If something must be tested that needs node-wide config, say so and ask the operators first.

## A sub-agent may ignore a clear instruction; the protocol must not depend on obedience

Three sub-agents told, in the first line of their brief, to call `report_to` before doing anything
else, all explored `/app` first and ran out of their small budget without reporting. The instruction
was received verbatim (the event is in their logs). So:

* delegation is verified mechanically (the message shapes: `report_to` -> event, `wait/2`,
  `wait_all/2`, the children record, worktrees), not by a model's compliance;
* the `Watcher` is what makes a disobedient child survivable: on a halt, death, or idle-without-report
  it sends the parent a `:no_report` / `:budget` / `:error` report and recovers the child's last
  assistant text, so work is never silently lost;
* give a sub-agent enough budget to work *and* report, or it may spend everything exploring.

## A raw tool result is 15 KB of someone else's API

`Nano.MCP.tools("fs")` returns every tool with its full JSON schema; printed raw it was ~15 KB
into context for information that a one-line summary carries. The same is true of a raw HTML page
(a Mintlify docs page was 180 KB, of which ~3 KB was prose). Everything that returns remote
content must summarise by default and page on request — this is why `Nano.Web` exists and why
`Nano.MCP.summary/0` does not print schemas.
