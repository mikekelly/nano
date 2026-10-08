# Bootstrap

The spec Nano Agent was first built from (`SPEC.md`) and the plan it was delivered by (`PLAN.md`),
kept off `main` so agents on the node never read them: `main` is mounted as `/app`. On `main`,
the code and `priv/system_prompt.txt` are the source of truth.
