# Seeding: background tasks (async shell)

Long-running commands should not hold an eval open. An agent should be able to start a
command in the background, carry on, and be told when it finishes.

## What to build

- Start: run a shell command in the background and return a handle at once. Options: a
  working directory, environment, a timeout after which it is killed, and where output
  goes (a file under `/data` or `/tmp`).
- Status and output: check whether it is still running, read its output so far (paged,
  tail-able), get the exit status when done.
- Completion as an event: when the command finishes or is killed, the agent that started
  it receives a mailbox message saying so, with the exit status and a pointer to the
  output — so it arrives as an `<event>` and can wake an idle agent.
- Control: kill a task; list an agent's tasks; tasks survive the agent's restart (the
  OS process keeps running; the handle and the completion message must still work).
- Keep output out of the context by default: the completion event carries a size and a
  path, not the output.

## What counts as done

An agent starts a build or a long test run, idles with a wakeup, is woken by the
completion event, reads the tail of the output and acts on it — tested, and visible on
the dashboard as a spawned process while it runs.
