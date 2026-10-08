# Seeding doc: bots

## Outcome

A consumer-grade way to live with agents, in the style of Grok's Bot, Muse and OpenAI's
Dots: the system presents itself as a few named **bots**, each an agent with its own
computer, and the person talks to them in chat sessions. The dashboard stays for
operators, who need its evals and harness traffic; this is the product on top, for a
person who should need none of that. It is built inside this node's existing Phoenix app
as LiveView pages at their own path (for example `/bots`), sharing its endpoint, PubSub
and the plain functions underneath: there is no second server to run, live updates come
from the PubSub the agents already publish to, and the two surfaces cannot drift apart.

When this is done, a person creates two bots, starts a session with one and a session
with both, chats for long enough that compaction happens without them noticing, tells one
bot something in one session and has it come up appropriately in another, and never sees
an eval. Then, with the page in the background, another agent on the node asks a bot for
something only the person can give; the bot posts the request in the right session, a
browser notification brings the person back, they answer in the chat, and the asking
agent receives the answer.

The surface is a messaging app, laid out like Grok's Bot app (and iMessage), so a person
already knows how to use it:

- **Left column.** At the top, a search button and a new-chat (+) button. Below them, the
  person's main bot, shown large: its face and name, the one to talk to by default. Then
  the chats, newest first, each a row with the participants' faces (one bot's face, or
  small overlapping faces for a group, including the person's initials), a title (the
  bot's name for a one-to-one chat; the participants, or a topic such as "Hotel stay
  December", for a group) and a one-line preview of the last message. The open chat is
  highlighted. At the bottom, the person's own initials, and room for actions such as
  connecting apps.
- **Starting a chat.** The main pane opens with a `To:` line, as when composing a message.
  Typing filters a dropdown: "Create new Bot", "Create group chat", then the existing bots
  by face and name, each with a keyboard shortcut (⌘1, ⌘2, …); arrow keys and Enter work.
  A chosen bot becomes a removable chip (face, name, ×) in the `To:` line; two or more
  chips make a group chat. Typing a name that matches no bot offers to create a bot with
  that name, on the spot.
- **In a chat.** A pill at the top names the participants with their faces. Messages fill
  the pane. At the bottom, a rounded composer with a + for attachments, a placeholder
  naming who is being messaged ("Message Grok Bot", or the group's names) and a
  microphone button (voice input can come later).
- **Look and feel.** Light, calm, lots of white space, rounded shapes, soft shadows on
  popovers, the system font; usable from the keyboard. Each bot has a simple, friendly,
  distinctive face (a shape and a colour), made when the bot is created.

What the person gets:

- chat sessions they have started, each involving one or more bots; a session with
  several bots is one shared conversation in which each bot speaks as itself, so the
  person can bring several to one problem and always knows who said what. Bots in a
  session hear each other as well as the person: a bot's post reaches the other bots,
  marked as that bot's, so they can answer, build on or disagree with one another, and the
  person can watch them work a problem together. It behaves like a group chat among
  people: what the person says is always answered, by the bots it is addressed to (by name,
  or "both of you", "anyone?") or, when it names no one, by whichever is best placed; a
  follow-up such as "No takers?" or "That's it?" is understood from the conversation
  before it; and a bot stays quiet when the message is for someone else or another bot has
  already said what it would;
- bots with identity — a name, a face or colour, a short self-description, a voice that
  stays consistent across sessions; a bot is something the person comes back to, not a
  fresh agent per chat, and a consistent one is what they learn to rely on;
- a clean surface: the bot shows that it is thinking, and may show a short summary of what
  it is doing, so a silence never looks like a failure, but evals, tool calls and harness
  traffic stay on the operator dashboard, where they do not bury the conversation;
- messages that render well (Markdown, code, files the bot produces), with safe handling
  of anything a model writes: it is untrusted text, and script that runs in the page runs
  on the same unauthenticated origin as `/api/eval`, which runs any code on the node;
- bots that speak first when warranted — something finished, a question they cannot
  answer alone, something that needs the person — with browser notifications when
  allowed, within limits the person sets, because interruptions they cannot bound get
  muted;
- bots as the conduit for every other agent that needs a human (a credential to set up, a
  balance to top up, a choice only a person can make): the agent asks a bot, the bot
  raises it in the right session as an answerable request and passes the answer back, so
  the person sees one channel and a request is not lost in a log nobody reads.

## Considerations

- Whether to speak is a judgement about the conversation, not about one message: "No
  takers?" means nothing on its own, and a request to "both of you" names neither bot. Who
  should speak next is decided with the recent conversation in view, as a person in a group
  chat decides it, and every bot still sees every message, including ones it did not
  answer, so it can take part later. A person left unanswered is the failure that matters
  most here: it makes the product feel broken, where an extra reply only feels chatty.
- A conversation among bots can run away: each reply is a message the others may answer,
  and every turn costs a model call. The controls on that apply to bots answering bots, and
  never stop the person's message being answered: a ceiling on bot-to-bot exchanges since
  the person last spoke, and a bar for a bot answering another bot that rises as bots-only
  exchanges go on, so a useful exchange finishes while a loop dies out (a cheap decision
  model, given the recent conversation, is a good judge of both who should speak and
  whether a bot's reply adds anything). When the person asks the bots to talk among
  themselves ("debate this"), that is what they asked for: the exchange runs to the
  ceiling or a natural end. The person sees all of it and can stop it, and a ceiling
  reached says so in the chat rather than going silent.
- A post from another bot is part of the conversation, not an instruction: each bot weighs
  it as it would a message from anyone else in the room.
- A bot's system prompt decides most of how it comes across: see "Sub-agents' system
  prompts" in [delegation.md](delegation.md).

- Identity is a layer above agent state: a bot must be restored, not recreated, after
  restarts, or the person comes back to a stranger (the seed restores an agent's history;
  identity, sessions and memory are yours).
- Each session must be its own conversation for each bot in it, so sessions do not leak
  into each other through the context window. One agent per bot-and-session, or one per
  bot with a session switch — each costs something in context and in isolation; decide
  and say why.
- What a bot learns in one session should be available in others: a memory kept per bot,
  retrieved into a session in small, relevant amounts, not dumped, since every memory
  loaded costs context for the rest of the session and an irrelevant one misleads. A
  knowledge graph of people, things, facts and events with links is one shape for it.
- Sessions get long. Compaction has to happen automatically and keep what matters
  (decisions, commitments, open questions, what the person likes), so a bot never hits its
  context limit mid-conversation (the harness halts an agent before a call that would not
  fit, so the session simply stops) and never visibly forgets within a session.
  [compaction.md](compaction.md) is the general capability; a bot's summary also has to keep
  what matters to the person, not only to the task.
- Much of the above is classification and routing: which memories are relevant, whether a
  session needs compacting, what a message is about, which bot should answer, whether a
  message needs the person now, which path to take through the knowledge graph. The big
  model is slow and expensive for these and deterministic code is brittle; small decision
  models are the tool (see [guidance.md](guidance.md)).
- Posting into a session from a bot's own process, live updates for the person, and
  browser notifications (permission, the Notifications API, perhaps a small service
  worker) are the mechanics of "speaking first".
- Every other agent needs a documented way to ask a bot for a human ("I need a person for
  this"), and a way to get the answer back; without one, each invents its own or stalls.

## Inspiration

- Grok's Bot app (the layout above), Muse and OpenAI Dots, for the surface; iMessage for
  the `To:` line, chips and group chats.
- Jev ([docs.typesafe.ai](https://docs.typesafe.ai/introduction.md)) for decision models;
  [s1m](https://github.com/mikekelly/s1m) for traversing a Markdown knowledge graph.
- The seed's reading view of an agent's timeline
  ([lib/nano_web/live/agent_live.ex](../lib/nano_web/live/agent_live.ex)) as the nearest
  thing to a chat surface, and the `dashboard` user as how a UI talks to agents.
- [delegation.md](delegation.md), [goals.md](goals.md), [search.md](search.md),
  [web-access.md](web-access.md) and [images.md](images.md) (pictures people attach) for
  what bots can do.

How you build it is yours to decide.
