# Seedings

A seeding is advice given to an agent before a task, to see which framings produce the
most interesting building behaviour (CHALLENGES.md, 11). The vocabulary: `main` is the
*seed*; a *seeding* is what we plant in an agent; a *seedling* is the branch that grows.

Seedings and tasks are kept apart so any seeding can be paired with any task. Both are
plain text, sent as the first message to a fresh agent from an operator user:

```bash
curl -s -XPOST localhost:4000/api/users -H 'content-type: application/json' -d '{"name":"operator"}'
python3 -c 'import json,sys; print(json.dumps({"to": sys.argv[1], "text": open(sys.argv[2]).read() + "\n\n" + open(sys.argv[3]).read()}))' \
  alice seedings/utilities-and-delegation.md seedings/tasks/review-the-harness.md \
  | curl -s -XPOST localhost:4000/api/users/operator/say -H 'content-type: application/json' -d @-
```

A seeding can instead be appended to a copy of `priv/system_prompt.txt` and passed as
`system_prompt_file`, which puts it in the system prompt rather than the first message.
Record which was used. Keep seedings true of the running system: the harness's value
depends on the agent being told the truth.

Keep every seeding that has been run, with the run it produced noted in CHALLENGES.md, even
when it did not work. What the run grew stays on a `seedling/<agent>-<what>` branch, never
in `main` (see AGENTS.md).
