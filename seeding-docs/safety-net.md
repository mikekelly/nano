# Seeding doc: a safety net

## Outcome

The node recovers by itself from the worst things that can happen to it, including ones its
own agents cause, without anyone outside the container stepping in. Agents here change the
running node, its source, its settings and its container, as they should; the cost is that
a mistake can take the whole node down with everything on it. When this is done, each of
these is survived, tested on a disposable copy of the node rather than the live one:

- **The node locks up.** The BEAM is still running but stops responding (a process storm,
  memory exhausted, a scheduler stuck). It is noticed within a minute or two and killed, so
  that the container restarts it, with its agents revived as the seed already does after a
  restart.
- **The node cannot boot.** A change to `/app` stops it compiling or starting, so every
  restart fails the same way. The last revision that booted and ran is started instead, and
  the change that broke it is kept, not thrown away, where someone can look at it.
- **Credentials are deleted.** The node's settings or the ChatGPT login are deleted or
  emptied, so no agent can call a model and none can repair it. They are restored as they
  were just before.
- **Someone is told.** Every recovery says what happened, when and what was done, where the
  operators and the agents will find it, because a node that silently repairs itself also
  silently hides what went wrong.

## How the container runs the node

- The container's first process is Docker's init, which runs `/app/bin/start`, which starts
  the BEAM. When the BEAM exits, the container stops, and Docker's restart policy starts it
  again: the same container, the same files, `/app/bin/start` again. A node that dies
  therefore already comes back by itself; one that locks up does not, because nothing
  exits.
- Every process in the container stops with it, including any the node started. A watcher
  started from the node lives as long as the container does, which is enough to notice a
  lock-up and kill the BEAM.
- The image, and the command a container starts with, are the operators': a change to the
  `Dockerfile` in `/app` takes effect only if they rebuild from it. `/app/bin/start` is the
  one thing that runs at every start and that you can change.
- `/app` (the operators' checkout) and `/data` survive the container being restarted and
  being recreated; other files, such as anything under `/opt`, survive a restart but not a
  recreation.
- The settings are in `/data/state/settings.json` and the ChatGPT login in
  `/data/state/chatgpt_auth.json`. The login's refresh token is replaced every time it is
  used, so only a copy taken at its latest change still signs in.

## Considerations

- `/app/bin/start` is the one part of `/app` the net depends on, and a broken one stops every
  start: keep it small, so that it is not what breaks, and keep anything bigger it runs
  where a change to `/app` cannot reach it.
- Knowing what "good" was is most of the work. Record the revision of `/app` that last booted
  and served (the node answering, agents able to call a model) as known-good, so that
  falling back goes to something that ran, not merely to something that compiled.
- Recovery must not destroy the evidence or the work: a rollback that throws away
  uncommitted changes, or a restore that overwrites a newer, valid setting, trades one loss
  for another. Keep what is replaced, and say where.
- A copy of credentials is still a credential: keep it with the same protection as the
  original (readable only by root, never logged or shown).
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

- Process supervisors such as runit, s6 and systemd's watchdog; Docker's health checks.
- Erlang's own `heart` (`erl -heart`), which restarts an emulator that stops responding.
- Deploy tools that keep the last good release and roll back to it automatically
  (blue-green and canary deploys).
- [background-tasks.md](background-tasks.md) for running and watching OS processes from the
  node, and [guidance.md](guidance.md), "You share this machine".

How you build it is yours to decide.
