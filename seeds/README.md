# Seeds

A seed is advice given to an agent before a task, to see which framings produce the most
interesting building behaviour (CHALLENGES.md, 11). Seeds and tasks are kept apart so any
seed can be paired with any task. Both are plain text, sent as the first message to a
fresh agent from an operator user:

```bash
curl -s -XPOST localhost:4000/api/users -H 'content-type: application/json' -d '{"name":"operator"}'
python3 -c 'import json,sys; print(json.dumps({"to": sys.argv[1], "text": open(sys.argv[2]).read() + "\n\n" + open(sys.argv[3]).read()}))' \
  alice seeds/utilities-and-delegation.md seeds/tasks/review-the-harness.md \
  | curl -s -XPOST localhost:4000/api/users/operator/say -H 'content-type: application/json' -d @-
```

A seed can instead be appended to a copy of `priv/system_prompt.txt` and passed as
`system_prompt_file`, which puts it in the system prompt rather than the first message.
Record which was used. Keep seeds true of the running system: the harness's value depends
on the agent being told the truth.

Keep every seed that has been run, with the run it produced noted in CHALLENGES.md, even
when it did not work. What the run grew stays on a `seedling/<agent>-<what>` branch, never
in `main` (see AGENTS.md).
