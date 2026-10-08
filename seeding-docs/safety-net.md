# Seeding doc: a safety net

## Outcome

The node recovers by itself from the worst things that can happen to it, including ones its
own agents cause, without anyone outside the container stepping in. Agents here change the
running node, its source, its settings and its container, as they should; the cost is that
a mistake can take the whole node down with everything on it. When this is done, each of
these is survived, tested on a disposable copy of the node rather than the live one:

- **The node locks up or dies.** The BEAM stops responding (a process storm, memory
  exhausted, a scheduler stuck) or exits. It is noticed within a minute or two and the node
  is brought back, with its agents revived as the seed already does after a restart.
- **The node cannot boot.** A change to `/app` stops it compiling or starting, so every
  restart fails the same way. The last version that booted and ran is brought back, and the
  change that broke it is kept, not thrown away, where someone can look at it.
- **Credentials are lost.** The provider settings are deleted or overwritten (an
  `openrouter_api_key`, the ChatGPT tokens, a key the operators supplied), so no agent can
  call a model and none can repair it. A known-good copy is restored.
- **Someone is told.** Every recovery says what happened, when and what was done, where the
  operators and the agents will find it, because a node that silently repairs itself also
  silently hides what went wrong.

## Considerations

- A safety net has to live outside what it protects. A check that runs inside the BEAM
  cannot rescue a BEAM that has locked up; one that runs from the code in `/app` cannot
  rescue a boot that `/app` breaks; a copy of the credentials in the same settings file goes
  when the file does. The container gives you an operating system to work in: the node is
  started by `/app/bin/start`, under an init process, with Docker's restart policy behind
  it, and anything you run there runs as root.
- Knowing what "good" was is most of the work. Record the version of `/app` that last booted
  and served (the node answering, agents able to call a model) as known-good, so that a
  rollback goes back to something that ran, not merely to something that compiled.
- Recovery must not destroy the evidence or the work: a rollback that throws away
  uncommitted changes, or a restore that overwrites a newer, valid setting, trades one loss
  for another. Keep what is replaced, and say where.
- A copy of credentials is still a credential: keep it with the same protection as the
  original (readable only by root, never logged or shown), and restore only what is actually
  missing or broken.
- Recovering in a loop is its own failure. Decide how many attempts a recovery makes, how far
  apart, and what it does when they are spent: stop and say so, leaving the node in a state
  someone can examine.
- The safety net is code like any other, and a broken one is worse than none: it can kill a
  healthy node or revert good work. Test each failure for real on a disposable copy of the
  node (its own container, its own data), never by breaking the node your agents are working
  on.
- Agents can turn it off, as they can change anything here. That is fine; make its state
  visible, so that an agent or an operator can tell at a glance whether the node is
  protected.
- Some losses are beyond any net inside the container: the container or its volume removed,
  the host gone. Say plainly which failures are covered and which are not.

## Inspiration

- Docker's restart policy and health checks; process supervisors such as runit, s6 and
  systemd's watchdog.
- Erlang's own `heart` (`erl -heart`), which restarts an emulator that stops responding.
- Deploy tools that keep the last good release and roll back to it automatically
  (blue-green and canary deploys).
- [background-tasks.md](background-tasks.md) for running and watching OS processes from the
  node, and [guidance.md](guidance.md), "You share this machine".

How you build it is yours to decide.
