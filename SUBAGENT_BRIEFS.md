Delegated findings and briefs

## fix-low
Low: Ops.processes/0 double walk of Process.list/0; Registry.lookup ArgumentError when Registry down (whereis/resolve should return nil); StateStore.delete/1 skips seq for id-less entry.

## fix-m2
M2: suspended dashboard user blocks every live-render ~1s (Nano.User.call/2 timeout in Components.refresh_inbox/1). Fix non-blocking; test.

## fix-m3
M3: NanoAgent event/2 and append/2 right-append O(n) and never trim; halted agents queue pending forever. Make appends amortized O(1), bound pending; keep transcript API-valid.

---

## Second delegation experiment (after the harness fixed the binding bug)

The operators restored the three sub-agents, halted on their budgets, and invited me to carry on.
I re-ran the delegation with the fix I had proposed: un-halt one agent (fix-m3) and brief it to
**report FIRST**, before any other work, since its M3 change was already recovered and integrated.

**Result: it did not report, again.** The resumed agent's own accumulated context beat the new
instruction. It (a) began re-applying its M3 patch to the freshly reset `/app`, then (b) went
completely off-task - it started debugging an unrelated `lazy_html` NIF "invalid ELF header" on
aarch64 - and halted on budget again, 36 turns later, having sent nothing. In between it had
modified `/app/lib/nano_agent.ex` and `test/nano_agent_test.exs`; I reverted both.

So the "tell them to report first" fix is not sufficient. The stronger lesson:

- **A sub-agent's context is a stronger driver than a new instruction.** A long-lived agent that
  was mid-task will keep going; a late "stop and report" competes with everything it has already
  read and done.
- **The reliable report is one you can read without the agent.** Here that was `git diff` again,
  plus polling `NanoAgent.info/1` for `halted: :budget`. Mailbox messages from sub-agents are
  best-effort and, on this harness, never arrived.
- **What would actually work:** start the sub-agent fresh for the report (a new agent whose entire
  job is to read the worktree and summarize), or have the sub-agent write its report to a file as
  its very first action and update it as it goes, or make the *last* turn budget-enforced: the
  harness could deliver a "you have N turns left, report now" note. None of those depends on the
  agent choosing to stop.

This is also, incidentally, more evidence for the M3/context-growth findings: the distraction
(`lazy_html`) is exactly the kind of large tool output that a context window fills with.
