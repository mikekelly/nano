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

## How pi does it

pi (github.com/badlogic/pi-mono, `packages/coding-agent/src/core/compaction/`) is a mature
coding agent whose compaction is a good reference. In outline:

- **When.** After a turn, if the context the provider last measured is past the model's
  window minus a reserve (16,384 tokens by default), and also on a context-overflow error or
  a reply cut off for length. The reserve leaves room for the agent's next request, and lets
  the summary call fit even if it had to read nearly the whole context.
- **What is kept.** Walking back from the newest message until about 20,000 tokens are
  covered, it cuts there: at a user or assistant message, never at a tool result, so every
  kept tool call keeps its result. If the cut falls inside a turn, the start of that turn is
  summarised separately, as a short checkpoint of the original request and the progress so
  far.
- **How the rest is summarised.** One separate model call, not the agent's own turn: its own
  system prompt, no tools, and one user message holding the older history as compact text,
  `[User]: …`, `[Assistant]: …`, `[Assistant tool calls]: name(arg=…)`, and
  `[Tool result]: …` cut to 2,000 characters, because a tool's outcome matters more than its
  full output. That keeps the input small enough for a single call, so a compaction takes
  seconds. The summary may use up to 80% of the reserve (about 13,000 tokens). The call
  writes no cache (it is one-off) and is retried on transient errors.
- **The summariser's system prompt:**

  > You are a context summarization assistant. Your task is to read a conversation between a
  > user and an AI assistant, then produce a structured summary following the exact format
  > specified.
  >
  > Do NOT continue the conversation. Do NOT respond to any questions in the conversation.
  > ONLY output the structured summary.

- **The summary's shape** is a fixed checkpoint, so the agent finds the same things in the
  same place every time: *Goal*; *Constraints & Preferences*; *Progress* (Done, In Progress,
  Blocked); *Key Decisions* with a brief rationale each; *Next Steps*; *Critical Context*,
  keeping exact file paths, function names and error messages. The files read and modified
  are listed after it, taken from the tool calls rather than from the model's memory.
- **The next compaction** sends only the messages since the last one, with the previous
  summary, and asks for it to be updated: keep what is there, move finished work to Done,
  add new decisions, drop what no longer matters. A long life is a series of updates, not a
  re-reading of everything.

## Considerations

- Automatic, not left to the model: the agent that most needs compacting is the one deep in
  a task, least likely to stop and do housekeeping, and once the harness has halted it for
  its context it can do nothing at all.
- A summary call costs about what reading its input and writing its output cost, and an
  agent's context is mostly tool output. Keeping the input to what the agent needs to
  continue (pi cuts each tool result to 2,000 characters) and the output to a fixed shape is
  what lets one call do it in seconds.
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
