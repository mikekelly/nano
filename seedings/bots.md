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
one session and has it come up appropriately in another, and never sees an eval.
