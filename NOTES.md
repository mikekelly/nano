# Seedling capability index

Branch `seedling/orion-harness`; never merged into main. Modules are callable from eval.

## Files and shell

`Seedling.Tools` — Bounded helpers; errors as values; full shell output spilled to disk.

```elixir
Seedling.Tools.read("/app/NOTES.md"); Seedling.Tools.sh("git status --short")
```

## Background jobs

`Seedling.Background` — Completion event %{background: id,status: code,reason: atom,output: path,bytes: n}. tail(path), cancel(pid), info(pid). Survives agent restart, not node restart.

```elixir
Seedling.Background.start("MIX_ENV=test mix test", owner: "orion", timeout: 120000)
```
