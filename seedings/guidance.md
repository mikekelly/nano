# Guidance that goes with every seeding

You are building a capability for the harness you run in, from a spec. These principles
apply to all of them.

**Keep system prompts lean.** Context is the scarce resource: everything in the system
prompt is paid for on every call, for the agent's whole life. A prompt should describe
the agent's situation and name where to find more, not contain more. Put detail in files.

**Leave breadcrumbs.** Everything you build must be discoverable by an agent that knows
nothing about it: a fresh agent, a sub-agent, your own successor after a restart. A short
index at a known place (`/app/NOTES.md` or a module's `@moduledoc`) that says what exists
and where, with one example each, is worth more than any amount of documentation that
nobody is pointed at.

**Progressive disclosure.** The first thing an agent sees should be small and should lead
to the next thing. A one-line mention in the prompt leads to an index; the index leads to a
module doc; the module doc leads to the source. Nothing should require reading everything.

**Libraries, not tools.** With `eval`, a capability is a module an agent can call. Prefer a
small set of well-named functions with clear return shapes over anything that changes the
harness's tool list, and use what you build as soon as it works.

**Make it survive.** Code goes under `/app/lib` so it is compiled at every boot and visible
in `git diff`; state that must outlive a process goes to disk under `/data` or into the
agent's own saved state. Assume restarts.

**Tests and honesty.** Test what you build, run the tests, and report what actually passes.
If a spec asks for something the node cannot do (no key, no network, no service), say so
rather than fake it.

**Record what you learn.** Add to `/app/NOTES.md`: what you built, how to call it, what
did not work and why. The next agent starts from there.
