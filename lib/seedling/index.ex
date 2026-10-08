defmodule Seedling.Index do
  @moduledoc "Discover installed seedling capabilities: entries/0, render/0, write_notes/1."
  def entries do
    [
      %{
        name: "Files and shell",
        module: Seedling.Tools,
        example:
          ~s|Seedling.Tools.read("/app/NOTES.md"); Seedling.Tools.sh("git status --short")|,
        detail: "Bounded helpers; errors as values; full shell output spilled to disk."
      },
      %{
        name: "Background jobs",
        module: Seedling.Background,
        example:
          ~s|Seedling.Background.start("MIX_ENV=test mix test", owner: "orion", timeout: 120000)|,
        detail:
          "Completion event %{background: id,status: code,reason: atom,output: path,bytes: n}. tail(path), cancel(pid), info(pid). Survives agent restart, not node restart."
      }
    ]
  end

  def render do
    "# Seedling capability index\n\nBranch `seedling/orion-harness`; never merged into main. Modules are callable from eval.\n\n" <>
      Enum.map_join(entries(), "\n", fn e ->
        "## #{e.name}\n\n`#{inspect(e.module)}` — #{e.detail}\n\n```elixir\n#{e.example}\n```\n"
      end)
  end

  def write_notes(path \\ "/app/NOTES.md"), do: Seedling.Tools.write(path, render())
end
