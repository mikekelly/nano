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

## Two shapes, and what each buys

A compaction needs a summary of the older part of the conversation. There are two sound
ways to get one, with different trade-offs; choose for your situation, and say why.

- **A separate summarising context.** The older history is written out as compact text
  and sent, in one user message, to a model given a different system prompt and no tools:
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
  matters; the full text stays in the log.
- **At the tip of the cached conversation.** A compaction instruction is appended to the
  agent's conversation as it is, and the model's reply is the summary. The Codex backend's
  own compaction works this way, from a trigger item at the end of the conversation
  (github.com/openai/codex, `codex-rs/core/src/compact_remote_v2.rs`). What it buys: the
  conversation is already cached from the agent's last call, so reading it is nearly free
  and only the summary is paid for in full; nothing is re-serialised, so the input is
  exactly what the provider measured; and the summary is written with everything in view,
  including the model's carried reasoning. What it needs: room at the tip for the
  instruction and the summary, which the reserve provides; the same model, since a cache
  does not carry over to another; and keeping the model to summarising, since it is still
  the agent, with its own system prompt and tools: allow no tool use for that call (adding or
  removing tools changes the cached prefix; turning tool use off does not), and reject a
  reply that is not a summary.

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
- Size things from measurements. After every call the provider reports exactly how many
  tokens the conversation took; only what was added since is unmeasured, and a cautious
  estimate is fine for that small gap. Anything else, such as the size of a re-serialised
  copy of the history, is best estimated from that measurement (this agent's own bytes per
  token, from what was sent and what it cost), or not estimated at all and left to the
  provider to refuse. A fixed rule of thumb applied to a whole history can be off several
  times over, and refuse a summary that would have fitted easily.
- If a summary really does not fit, cut harder or summarise in parts; never halt for size
  without trying. Which parts of a history are large depends on the agent: a builder's
  context fills with tool output, an orchestrator's with the reports it receives, and every
  agent's with the code it writes into its calls.
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
