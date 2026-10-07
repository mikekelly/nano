# Seeding: bots

A consumer-grade way to live with agents, in the style of Grok's Bot, Muse and OpenAI's
Dots: the system presents itself as a few named **bots**, each an agent with its own
computer, and the person talks to them in chat sessions. The dashboard stays for operators;
this is the product on top.

## What the person sees

- **A sidebar of chat sessions** the person has started. Each session involves one or more
  of their bots; a session with several bots is one shared conversation in which each bot
  speaks as itself.
- **Bots with identity**: a name, a face or colour, a short self-description, a voice that
  stays consistent across sessions. A bot is a long-lived thing the person comes back to,
  not a fresh agent per chat.
- **A clean surface**: the bot shows that it is *thinking* (and, as Muse and Dots do, may
  show a short summary of what it is doing), but the evals, tool calls and harness traffic
  are not on this screen. The operator's dashboard still has all of it.
- Messages render well: Markdown, code, files the bot produces, with safe handling of
  anything a model writes.
- **Bots speak first when it is warranted.** A bot can post into a session it belongs to
  without being asked — to report that something finished, to ask a question it cannot
  answer alone, to flag that something needs the person — and the person is told, with
  browser notifications when they have allowed them, so a bot's message reaches them
  even when the page is not in front of them. Which sessions a bot may use for this, and
  how often, is the bot's judgment within limits the person sets; a decision model is the
  right tool for "does this need the person now?".
- **Bots as the conduit for every other agent.** Operators' agents on this node (and
  agents on other machines that talk to it) often need a human: a credential to set up, an
  account balance to top up, a choice only a person can make. Rather than each of them
  finding the person, they ask a bot, and the bot raises it in the right session as a
  request the person can answer there, then passes the answer back. So a bot's inbox is an
  interface other agents can rely on, with a documented message shape for "I need a human
  for this", and the person sees one channel, not many.

## What that requires underneath

- **Bot identity**: a persistent record per bot (name, description, prompt partials,
  model and effort, what it knows) that outlives any one process; a bot is restored, not
  recreated, after restarts (the seed already restores an agent's history; identity is the
  layer above that).
- **Isolated threaded context**: each chat session is its own conversation for each bot in
  it, so what was said in one session does not leak into another through the context
  window. A bot in three sessions is three conversations with one identity.
- **Cross-thread memory**: what a bot learns in one session is available in others, as a
  memory store it writes to and reads from — a knowledge graph of people, things, facts
  and events with links between them, kept per bot and shared between a bot's sessions.
  Retrieval into a session must be small and relevant, not a dump.
- **Autocompaction**: sessions get long; compact them automatically when needed, keeping
  what matters (decisions, commitments, open questions, what the person likes), so a bot
  never hits its context limit mid-conversation and never visibly "forgets" within a
  session. The seed has no compaction; the compaction mechanism the `reviewer` run found
  (rewrite the stored transcript, keep every tool call answered) is the starting point.
- **Proactive messaging and notifications**: a bot that initiates must be able to post
  into a session from its own process (not only in reply to a turn), the session must
  update live for the person, and browser notifications need the page to ask permission
  and a small service worker or the Notifications API from the LiveView page.
- **Decision models, not only LLMs**: much of the above is classification and routing —
  which memories are relevant, whether a session needs compacting, what a message is
  about, which bot should answer, which path to take through the knowledge graph. Doing
  this with the big model on every turn is slow and expensive; doing it with deterministic
  code is brittle. Use small, cheap models (classifiers, embedding models, or whatever
  "decision model" is available on this node) for these rapid, low-stakes decisions, and
  reserve the LLM for the conversation itself. Graph traversal in particular — choosing
  which links to follow from a memory to the ones worth loading — is a place for a cheap
  model rather than either a hand-written rule or a full LLM call.

## What to build

- The GUI inside this node's existing Phoenix app, as LiveView pages at their own path
  (for example `/bots`), styled for a person rather than an operator, sharing the app's
  endpoint, PubSub and the plain `Nano.Ops`-style functions underneath. Not a separate
  front end.
- Bots as a layer over agents: one agent per (bot, session) or one agent per bot with a
  session switch — decide, and say what each choice costs in context and in isolation.
- The memory store and its retrieval, the autocompaction, and the decision-model layer,
  each as a module with a small interface, each with breadcrumbs.

## What counts as done

A person creates two bots, starts a session with one and a session with both, chats for
long enough that compaction happens without them noticing, tells one bot something in
one session and has it come up appropriately in another, and never sees an eval. Then,
with the page in the background, another agent on the node asks a bot for something only
the person can give; the bot posts the request in the right session, the browser
notification brings the person back, they answer in the chat, and the asking agent
receives the answer.

## Related

- Builds on: [delegation.md](delegation.md) (bots as agents), [goals.md](goals.md), [search.md](search.md) and [web-access.md](web-access.md) (what bots can do), [guidance.md](guidance.md) (decision models; lean prompts; role and abstraction level).
- Compaction: the mechanism `reviewer` found — rewrite the stored transcript from outside, keeping every tool call answered — in [RUNS.md](RUNS.md), branch `seedling/reviewer-harness-review` (`Nano.Compact`).
- In the seed: the dashboard is a Phoenix LiveView app in the same node ([SPEC.md, Web dashboard](../SPEC.md#web-dashboard)); the reading view of an agent's timeline is the nearest thing to a chat surface ([lib/nano_web/live/agent_live.ex](../lib/nano_web/live/agent_live.ex)); the `dashboard` user is how the UI talks to agents ([SPEC.md, Operator access](../SPEC.md#operator-access)).
- Decision models: Jev ([docs.typesafe.ai](https://docs.typesafe.ai/introduction.md)); knowledge-graph traversal as in [s1m](https://github.com/mikekelly/s1m).
