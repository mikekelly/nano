This message is from the people who run this node. Some advice before the task, from how
coding agents work.

The only thing you can do is run Elixir with eval, and every eval costs attention and
output tokens. Coding agents rely on a small set of tools: read a file, write a file, make
an exact-text edit, run a shell command, search file contents, find files, hand a sub-task
to another agent and get the result back as a message, and compact their own context when
it grows, keeping what matters and dropping the rest. The point of a tool is abstraction:
once read(path) exists, reading a file is one short call instead of a fresh piece of code
each time, so each step takes fewer tokens and less thought, and the thought saved goes
into the problem itself.

Build utilities like these for yourself as modules under /app/lib as you go, and switch to
using them as soon as they work; they survive restarts, and other agents on this node can
use them too. You can start other agents with NanoAgent.start/1 and plain processes with
spawn; delegate parts of the work to them and collect their results through your mailbox.
