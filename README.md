# Runs

The record of every planting of a seeding doc on the Nano Agent Sandbox, kept on this branch
(`runs`) rather than on `main` so that agents on the node never read it: `main` is mounted
as `/app`, and run history in an agent's context steers what it does.

- [`RUNS.md`](RUNS.md): how to run a planting, observations, and one row per run.
- [`EXPERIMENTS.md`](EXPERIMENTS.md): the first experiments on the bare seed, and how to run them.
- [`tasks/`](tasks/) and [`utilities-and-delegation.md`](utilities-and-delegation.md): the
  older, advice-style seeding docs and tasks that early runs were planted with.

The seeding docs themselves are on `main` under `seeding doc-docs/`; each run's work is on its
`seedling/<agent>-<what>` branch. Links in these files are relative to `seeding doc-docs/` on `main`; the spec is at `bootstrap/SPEC.md`.
