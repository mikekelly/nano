# Seeding doc: compaction

## Outcome

An agent can work for as long as its job takes, not only until its context is full. Every
agent's conversation only grows, and when it nears the agent's context limit the harness
stops calling the model: without compaction, an agent's working life ends there, mid-task,
unable even to report what it found. When this is done, an agent's conversation is
compacted automatically before a model call that would otherwise leave too little room:
what the agent received (its brief, the messages people and other agents sent it) is kept
in their own words, and everything it did is replaced by a structured summary placed last,
at the tip, where it carries on from. It stays the same agent, with the same name, pid and
mailbox, so the people, sub-agents and processes that reach it, and the ones it started that
report to it, carry on as before. It is told plainly, in the conversation, that its history
was compacted, by what, and where the full record is. This works for every agent on the
node, including sub-agents, without any of them having to remember to do it — tested on a
real agent whose context crosses the threshold, not only in unit tests.

## A proposal

This is one way to do it, with numbers to start from; change what does not hold up.

**Compact at the tip of the cached conversation.** The summary is written by the agent's own
model, at the end of its own conversation, so the whole history is read from the provider's
cache instead of being paid for again, nothing is re-serialised or cut, and the model has
everything in view, including its carried reasoning. A retry costs almost nothing, because
the history is still the cached prefix: on the Codex backend, an identical retry, and a
request with the same history and a different tip, each read all but the final partial cache
block from the cache.

1. **When.** Before each model call, compact if the context the provider last measured,
   plus a cautious estimate of what has been added since, would leave less than a reserve of
   16,384 tokens. The reserve is room for the compaction note and the summary; on a window of
   a few hundred thousand tokens it is late enough to use nearly all of the context and early
   enough that compaction never meets the harness's own stop.
2. **The note.** The harness appends a note of its own at the tip, as it delivers any note,
   plain enough not to be mistaken for anything else, for example:

   > The context limit is near: automatic compaction is starting. Do not ignore this. Call
   > `Compaction.provide_summary(text)` from `eval` with a summary of this conversation in the
   > format below. Everything above, except the messages you received, will be replaced by
   > it, and the next reader is you, with no memory of anything here except this summary and
   > those messages. If a summary from an earlier compaction is above, update it: keep what is
   > there, move finished work to Done, add new decisions, drop what no longer matters.

   The note also states the summary's format and its length (below).
3. **The reply.** Accept it only if its code is exactly one call,
   `Compaction.provide_summary("…")` with a string, and take the summary from it without
   running anything else: an agent mid-compaction should not run other code. A summary that
   is empty or over its length does not count.
4. **Retries.** Anything else is not kept: send the same request again, unchanged, up to three
   times. If none of them gives a summary, halt the agent with a reason that says so and a
   note telling it what happened; its full history is still in the log, and an operator can
   un-halt it to try again.
5. **Voluntary compaction.** The same function, called by the agent itself from `eval` with
   its own summary whenever it judges the moment right: between tasks, say, or before starting
   something large once more than about half the context is used. No note is needed. It takes
   effect once the eval's turn is answered, so no tool call is ever left without its result.
6. **The summary.** Aim for 2,000 to 8,000 tokens; never more than 12,000. A fixed checkpoint,
   so the agent finds the same things in the same place every time: *Goal*; *Constraints &
   Preferences*; *Progress* (Done, In Progress, Blocked); *Key Decisions*, each with a brief
   reason; *Next Steps*; *Critical Context*, keeping exact file paths, function names and
   error messages. The harness can add the files the agent read and changed, taken from its
   calls rather than from the model's memory.
7. **What is carried over.** Of the agent's own turns, nothing: its messages, calls and
   results are what the summary replaces. Of what it received, its events (the brief, the
   operators' and its parent's messages, people's requests), as many as fit in about a fifth
   of the window, chosen newest first, and always the first brief it was given, however old:
   these are what the work must keep answering to, so they survive word for word. Reports
   from its own sub-agents are results, which the summary carries. The harness's own notes
   (budget lines, the compaction note) are not kept.
8. **The order of the new context.** The system prompt, unchanged; then the carried-over
   events, in their original order, with no marker; then the summary, last, with a
   preamble that says truthfully what it is: "Your conversation before this point was
   compacted. The messages above are ones you received, kept in their own words; this is your
   summary of everything else." The summary is then what the model attends to most as it
   carries on. Anything that arrived during the compaction is delivered after it.

## Considerations

- Automatic, not left to the model: the agent that most needs compacting is the one deep in a
  task, least likely to stop and do housekeeping, and once the harness has halted it for its
  context it can do nothing at all.
- A summary fits by construction: compaction starts before the context reaches its limit, the
  summary is written at the tip of that same context, and its own length fits in the
  reserve.
  There is nothing to measure first, and a size check that can refuse is only a way to fail.
- On the ChatGPT subscription the backend accepts no limit on a reply's length, so a summary
  there is bounded only by what it is asked to write: state the length in the note and check it
  when the summary comes back. OpenRouter takes a limit (`max_tokens`).
- A summary over a large context can take a while; time limits must allow for it, and a dropped
  connection is a reason to retry, not to halt.
- The conversation lives in the agent's state, and the harness acts on it every turn, so
  changing it must not race a model request or an eval in flight; and whatever the harness
  derives from it (the context used, which its pre-call check reads) has to be true again
  afterwards, or the agent stays halted.
- The harness's pre-call check is the last line of defence against a request the model cannot
  take; compaction should make it rarely needed, not loosen it.
- After a compaction the conversation is a new prefix, so the next call is paid in full; that
  is a reason not to compact sooner than needed.
- What the agent keeps on disk (its goals, its orientation, its code) survives compaction
  untouched, which is why keeping them current makes a compaction cheap and safe. The log
  under `/data/logs` keeps the whole conversation, so nothing is lost to operators.
- The summary sets the voice of everything after it: the agent imitates its own context. A
  summary written terse but intelligible helps an agent that had slid into shorthand recover
  clarity, where one that copies the shorthand locks it in.
- The note and the preamble must be true about who compacted and why: an agent that believes a
  person intervened acts differently from one that knows the harness did, and one told that
  someone else wrote its summary would be told something false about itself.

## Inspiration, for the compaction prompt

- pi (github.com/badlogic/pi-mono, `packages/coding-agent/src/core/compaction/`): its summary
  and update prompts in `compaction.ts`, and the structured checkpoint they ask for.

- The Codex CLI (github.com/openai/codex, `codex-rs/prompts/templates/compact/prompt.md`),
  whose compaction prompt asks for current progress and key decisions; important context,
  constraints and preferences; what remains to be done; and any critical data, examples or
  references needed to continue.
- [goals.md](goals.md): goals on disk are what a summary can point to instead of repeat.

How you build it is yours to decide.
