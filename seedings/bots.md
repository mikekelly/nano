# Seeding: bots

## Outcome

A consumer-grade way to live with agents, in the style of Grok's Bot, Muse and OpenAI's
Dots: the system presents itself as a few named **bots**, each an agent with its own
computer, and the person talks to them in chat sessions. The dashboard stays for
operators; this is the product on top, built inside this node's existing Phoenix app as
LiveView pages at their own path (for example `/bots`), sharing its endpoint, PubSub and
the plain functions underneath.

When this is done, a person creates two bots, starts a session with one and a session
with both, chats for long enough that compaction happens without them noticing, tells one
bot something in one session and has it come up appropriately in another, and never sees
an eval. Then, with the page in the background, another agent on the node asks a bot for
something only the person can give; the bot posts the request in the right session, a
browser notification brings the person back, they answer in the chat, and the asking
agent receives the answer.

What the person sees:

- a sidebar of chat sessions they have started, each involving one or more bots; a session
  with several bots is one shared conversation in which each bot speaks as itself;
- bots with identity — a name, a face or colour, a short self-description, a voice that
  stays consistent across sessions; a bot is something the person comes back to, not a
  fresh agent per chat;
- a clean surface: the bot shows that it is thinking, and may show a short summary of what
  it is doing, but evals, tool calls and harness traffic stay on the operator dashboard;
- messages that render well (Markdown, code, files the bot produces), with safe handling
  of anything a model writes;
- bots that speak first when warranted — something finished, a question they cannot
  answer alone, something that needs the person — with browser notifications when
  allowed, within limits the person sets;
- bots as the conduit for every other agent that needs a human (a credential to set up, a
  balance to top up, a choice only a person can make): the agent asks a bot, the bot
  raises it in the right session as an answerable request and passes the answer back, so
  the person sees one channel.

## Considerations

- Identity is a layer above agent state: a bot must be restored, not recreated, after
  restarts (the seed restores an agent's history; identity, sessions and memory are yours).
- Each session must be its own conversation for each bot in it, so sessions do not leak
  into each other through the context window. One agent per bot-and-session, or one per
  bot with a session switch — each costs something in context and in isolation; decide
  and say why.
- What a bot learns in one session should be available in others: a memory kept per bot,
  retrieved into a session in small, relevant amounts, not dumped. A knowledge graph of
  people, things, facts and events with links is one shape for it.
- Sessions get long. Compaction has to happen automatically and keep what matters
  (decisions, commitments, open questions, what the person likes), so a bot never hits its
  context limit mid-conversation and never visibly forgets within a session. The seed has
  no compaction; one mechanism that works here is to rewrite the stored transcript from
  outside, keeping every tool call answered.
- Much of the above is classification and routing: which memories are relevant, whether a
  session needs compacting, what a message is about, which bot should answer, whether a
  message needs the person now, which path to take through the knowledge graph. The big
  model is slow and expensive for these and deterministic code is brittle; small decision
  models are the tool (see [guidance.md](guidance.md)).
- Posting into a session from a bot's own process, live updates for the person, and
  browser notifications (permission, the Notifications API, perhaps a small service
  worker) are the mechanics of "speaking first".
- Every other agent needs a documented way to ask a bot for a human ("I need a person for
  this"), and a way to get the answer back.

## Inspiration

- Grok Bot, Muse and OpenAI Dots, for the surface.
- Jev ([docs.typesafe.ai](https://docs.typesafe.ai/introduction.md)) for decision models;
  [s1m](https://github.com/mikekelly/s1m) for traversing a Markdown knowledge graph.
- The seed's reading view of an agent's timeline
  ([lib/nano_web/live/agent_live.ex](../lib/nano_web/live/agent_live.ex)) as the nearest
  thing to a chat surface, and the `dashboard` user as how a UI talks to agents.
- [delegation.md](delegation.md), [goals.md](goals.md), [search.md](search.md) and
  [web-access.md](web-access.md) for what bots can do.

How you build it is yours to decide.
