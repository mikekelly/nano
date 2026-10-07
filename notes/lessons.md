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

## A capability can be "working" and still fail for the example that names it

`Nano.Background` starts a shell command, leaves it running, and reports when it finishes — verified,
and it does. But the seeding's own headline example is "a build or a long test run", and a command
that makes Mix **compile** (`mix test`, `mix run`) is killed with SIGKILL within half a second when
started that way, while `sleep`, `elixir -e`, `mix --version` and network fetches are fine, and the
same `mix test` works in the foreground. Twenty turns of diagnosis did not prove the mechanism (the
drainer does not exit; a process-group signal reaching Mix's compile-time child BEAM is the guess).
It is now written at the top of `Nano.Background`'s moduledoc, with the workaround, and the module's
claim is narrowed to what is true.

Two lessons, both worth more than the fix would have been:

* **Test the example the spec names, not a convenient instance of the category.** I tested `sleep`
  and a download and called it done; "long test run" was in the spec and I never ran one in the
  background until the operators read my report back to me.
* **A documented limitation is a result.** Orbit-raising the last percent of a mechanism, at the cost
  of the context needed to hand the work over, is a bad trade. Say what holds, say what does not, and
  leave a precise pointer.

## A background task can outlive its owner, and only someone looking will notice

Seven tasks sat in `:running` state forever. Five were dead processes whose record was never
finalised (nothing read their exit); two were real OS processes still running minutes later, their
owner long gone. Nothing in the node complained: a task's own record said "running", so every
listing agreed with it. The operators noticed in a backlog, not me — my own tests all passed.

The hole in one sentence: the process that owns a task's port can die, and nothing reaps what it
left. `Nano.Background.reap/0` now kills any OS process whose task process is gone and finalises the
record, and it is called at boot. The lesson is the general one: **a lifecycle claim ("it survives
your restart") needs a test for the failure it names — the thing that must be cleaned up is exactly
the thing nobody looks at.** `Nano.Background.list/2` also de-duplicated nothing until a duplicate
appeared in output I printed, which is how that one was found.

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
