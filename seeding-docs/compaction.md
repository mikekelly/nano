# Seeding doc: compaction

## Outcome

An agent can work for as long as its job takes, not only until its context is full. Every
agent's conversation only grows, and when it nears the agent's context limit the harness
stops calling the model: without compaction, an agent's working life ends there, mid-task,
unable even to report what it found. When this is done, an agent's conversation is
compacted automatically before a model call that would otherwise leave too little room:
the older part is replaced by a structured summary and the most recent part is kept as it
was, so the agent carries on mid-thought. It stays the same agent, with the same name, pid
and mailbox, so the people, sub-agents and processes that reach it, and the ones it started
that report to it, carry on as before. It is told plainly, in the conversation, that its
history was compacted, by what, and where the full record is. This works for every agent on
the node, including sub-agents, without any of them having to remember to do it — tested on
a real agent whose context crosses the threshold, not only in unit tests.

## How: at the tip of the cached conversation

Compact at the tip: it reads the history from the provider's cache instead of paying to read
it again, keeps everything at full fidelity, and makes a retry nearly free. On the Codex
backend, an identical retry, and a request with the same history and a different tip, each
read all but the final partial cache block from the cache. A separate summarising context
is there for what the tip cannot do.

The harness appends a note of its own at the end of the agent's conversation, as it delivers any note, and the model's reply carries
the summary. The Codex backend's own compaction works this way, from a trigger item at the
end of the conversation (github.com/openai/codex, `codex-rs/core/src/compact_remote_v2.rs`).
The note says what is happening and what is needed, plainly enough that it is not
mistaken for anything else: the context limit is near, automatic compaction is starting,
do not ignore this; call a function such as `Compaction.provide_summary(text)` from `eval`
with a summary of a stated shape (the checkpoint format below), and why: everything above
will be replaced by it. The harness accepts the reply only if its code is exactly that one
call with a string, and takes the summary from it without running anything else (an agent
mid-compaction should not run other code). Anything else is not kept: the harness sends
the same request again, unchanged, up to a set number of times, and then gives up and
says so. A retry is cheap: providers cache by prefix, the harness holds the
conversation, and the tools stay as they were (adding or removing one changes the cached
prefix), so the whole history is read from the cache and only the note and the new reply
cost anything. What this shape buys: nearly free reading; nothing re-serialised, so the
input is exactly what the provider measured; and the summary written with everything in
view, including the model's carried reasoning. What it needs: room at the tip for the note
and the summary, which the reserve provides; and the same model, since a cache does not
carry over to another.

The same function is how an agent compacts **voluntarily**: it calls it from `eval` with
its own summary whenever it judges the moment right (between tasks, say), and no note is
needed.

**When the tip cannot be used: a separate summarising context.** Two cases need it: a
conversation already past its window, which leaves no room at the tip, and a summary
wanted from a different, cheaper or faster model, which cannot use this model's cache. The older history is written out as compact
text and sent, in one user message, to a model given a different system prompt and no tools:
its only job is to read a transcript and write a summary. pi works this way
(github.com/badlogic/pi-mono, `packages/coding-agent/src/core/compaction/`); its
summariser's system prompt is:

> You are a context summarization assistant. Your task is to read a conversation between a
> user and an AI assistant, then produce a structured summary following the exact format
> specified.
>
> Do NOT continue the conversation. Do NOT respond to any questions in the conversation.
> ONLY output the structured summary.

What it buys: a clean change of role (the summariser is not the agent, so it cannot answer
the last message, call a tool or carry on the task); it works even when the conversation
no longer fits its own window, since it reads a compressed copy; it works the same on any
provider, and the summary can come from a different, cheaper or faster model. What it
costs: the whole older history is read again, uncached and in full. pi keeps that small by
cutting each tool result to 2,000 characters in what the summariser reads (the outcome
matters more than the whole output), which also keeps the summariser's attention on what
matters; the full text stays in the log. What is cut is what came back, never what the
agent wrote: its calls, with the code and the comments explaining why, are kept whole. A
file the agent read is cut too, so the summary should say where things are (pi lists the
files read and modified) for the agent to read again; and the summariser never sees the
model's own reasoning, which only compacting at the tip keeps in view.

Either way:

- **When.** pi compacts after a turn if the context the provider last measured is past the
  model's window minus a reserve (16,384 tokens by default), and also on a context-overflow
  error or a reply cut off for length. The reserve leaves room for the agent's next request;
  and because the summary is capped at 80% of the reserve (about 13,000 tokens), a summary
  call fits within the window even if it has to read the older history uncut, or is written
  at the tip.
- **What is kept.** Walking back from the newest message until about 20,000 tokens are
  covered, pi cuts there: at a user or assistant message, never at a tool result, so every
  kept tool call keeps its result. If the cut falls inside a turn, the start of that turn is
  summarised separately, as a short checkpoint of the request and the progress so far.
- **The summary's shape** is a fixed checkpoint, so the agent finds the same things in the
  same place every time: *Goal*; *Constraints & Preferences*; *Progress* (Done, In Progress,
  Blocked); *Key Decisions* with a brief rationale each; *Next Steps*; *Critical Context*,
  keeping exact file paths, function names and error messages. The files read and modified
  are listed after it, taken from the tool calls rather than from the model's memory.
- **Framing.** After a compaction, the reader of the summary is the agent itself, with no
  memory beyond it. Asking for a handoff to that reader ("your conversation is about to be
  replaced by what you write now; the next reader is you, with no memory of anything here
  except this") is true, and it draws out a self-contained brief rather than notes that
  assume the context they replace.
- **The next compaction** sends only the messages since the last one, with the previous
  summary, and asks for it to be updated: keep what is there, move finished work to Done,
  add new decisions, drop what no longer matters. A long life is a series of updates, not a
  re-reading of everything.

## Considerations

- Automatic, not left to the model: the agent that most needs compacting is the one deep in
  a task, least likely to stop and do housekeeping, and once the harness has halted it for
  its context it can do nothing at all.
- A summary fits by construction: compaction starts before the context reaches its limit,
  the summariser reads the older part of that same context (as it is at the tip, or as a
  copy that is usually smaller once tool output is cut), and the summary's own length fits
  in the reserve. So there is nothing to measure first, and a size check that can refuse is
  only a way to fail; if a provider ever does refuse, cut harder or summarise in parts
  rather than halt. Cutting what the summariser reads is for cost and focus alone, and what
  is worth cutting depends on the agent: a builder's context fills with tool output, an
  orchestrator's with the reports it receives, and every agent's with the code it writes
  into its calls.
- On the ChatGPT subscription the backend accepts no limit on a reply's length, so a
  summary call there is bounded only by what it is asked to write: say how long the summary
  may be, and check its length when it comes back. OpenRouter takes a limit (`max_tokens`).
- A summary call over a large context can still take a while; time limits must allow for
  the real size, and a failed call (a dropped connection, a provider error) should be
  retried before the agent is left halted.
- The conversation lives in the agent's state, and the harness acts on it every turn, so
  changing it must not race a model request or an eval in flight; and whatever the harness
  derives from it (the context used, which its pre-call check reads) has to be true again
  afterwards, or the agent stays halted.
- The harness's pre-call check is the last line of defence against a request the model
  cannot take; compaction should make it rarely needed, not loosen it.
- Compaction resets the provider's cached prefix, so the next call is paid in full; that is
  a reason not to compact sooner than needed.
- What the agent keeps on disk (its goals, its orientation, its code) survives compaction untouched,
  which is why keeping them current makes a compaction cheap and safe. The log under
  `/data/logs` keeps the whole conversation, so nothing is lost to operators.
- The summary and the turns kept verbatim set the voice of everything after them: the
  agent imitates its own context. A summary written terse but intelligible helps an agent
  that had slid into shorthand recover clarity, where one that copies the shorthand locks
  it in.
- The note telling the agent its history was compacted must be true about who did it and
  why: an agent that believes a person intervened acts differently from one that knows the
  harness did.
- If summarising fails, the agent must not be left halted silently; it should be clear to
  it, and to operators, what happened.

## Inspiration

- pi's compaction code, above: `compaction.ts` (`shouldCompact`, `findCutPoint`, the
  summary and update prompts) and `utils.ts` (`serializeConversation`, the summariser's
  system prompt, the file lists).
- The Codex backend's own compaction, which compacts server-side from a trigger at the end
  of the conversation and returns an encrypted item (github.com/openai/codex,
  `codex-rs/core/src/compact_remote_v2.rs`; OpenAI's compaction guide).
- [goals.md](goals.md): goals on disk are what a summary can point to instead of repeat.

How you build it is yours to decide.
