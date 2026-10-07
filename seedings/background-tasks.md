# Seeding: background tasks

## Outcome

Long-running commands do not hold an eval open. When this is done, an agent starts a
build or a long test run, carries on or idles with a wakeup, is told by a mailbox message
when the command finishes or is killed (with its exit status and where its output is),
reads the tail of the output, and acts on it — tested, and visible on the dashboard as a
spawned process while it runs. Tasks survive the agent's restart: the OS process keeps
going, and the completion message still arrives.

## Considerations

- Output stays out of the context by default: the completion message carries a size and a
  path, not the output; reading is paged and tail-able.
- The seed's eval runs in a task with its own timeout and kills what it spawned; a
  background task has to live somewhere that an agent's restart does not kill.
- Working directory, environment, a timeout after which the command is killed, and
  killing on demand are the controls an agent will want.
- Coding agents' conventions for shell output (keep the tail, save the whole output to a
  file whose path is returned) are in [guidance.md](guidance.md).

## Inspiration

- Claude Code's `run_in_background` and pi's bash tool.
- Elixir ports and `Task.Supervisor`; `erlexec` on Hex if port handling gets in the way.

How you build it is yours to decide.
