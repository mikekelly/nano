# Seeding: background tasks

## Outcome

Long-running commands do not hold an eval open: an eval is killed at its timeout (30 s by
default), and while one runs the agent's turn cannot move on. When this is done, an agent
starts a build or a long test run, carries on or idles with a wakeup, is told by a mailbox
message when the command finishes or is killed (with its exit status and where its
output is, so it can act without running it again), reads the tail of the output, and
acts on it — tested, and visible on the dashboard as a spawned process while it runs, so
operators can see what is running, and for whom, and stop a runaway. Tasks survive the
agent's restart: the OS process keeps going, and the completion message still arrives;
otherwise a restart throws away the work and leaves the agent waiting for news that never
comes.

## Considerations

- Output stays out of the context by default: the completion message carries a size and a
  path, not the output, because a build's output can be megabytes of which a few lines
  matter; reading is paged and tail-able.
- The seed's eval runs in a task that is killed at its timeout and when its agent stops or
  restarts, taking what is linked to it (processes, ports) with it; a background task has
  to live somewhere that an agent's restart does not kill.
- The dashboard credits a process to an agent by following who started it (its parent,
  `$callers`, `$ancestors`), which a process placed outside the agent's tree may not lead
  back to.
- Working directory, environment, a timeout after which the command is killed, and
  killing on demand are the controls an agent will want.
- Coding agents' conventions for shell output (keep the tail, save the whole output to a
  file whose path is returned) are in [guidance.md](guidance.md).

## Inspiration

- Claude Code's `run_in_background` and pi's bash tool.
- Elixir ports and `Task.Supervisor`; `erlexec` on Hex if port handling gets in the way.

How you build it is yours to decide.
