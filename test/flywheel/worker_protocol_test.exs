defmodule Nano.Flywheel.WorkerProtocolTest do
  use ExUnit.Case, async: true

  test "fresh worker composition retains whole seed, principles, builder and common protocol" do
    root = File.cwd!()
    base = String.duplicate("a", 40)

    {:ok, composed} =
      Delegation.Prompt.compose(
        name: "fixture-worker",
        parent: "altair",
        level: :worker,
        job: "Exactly one resolved unit",
        prompt_root: root,
        cwd: root,
        flavours: ["builder", "worker"],
        worktree: %{path: root, branch: "seedling/fixture", revision: base},
        pre: ["docs/flywheel/u03/api.md"]
      )

    assert String.starts_with?(composed.prompt, File.read!("prompts/seed.txt"))

    for text <- [
          "Know your role",
          "engineering builder",
          "exactly one resolved",
          "Parent alone",
          "claim-generation",
          base
        ] do
      assert String.contains?(composed.prompt, text)
    end

    assert Enum.map(composed.provenance.partials, &Path.basename(&1.path)) == [
             "principles.txt",
             "builder.txt",
             "worker.txt"
           ]
  end

  test "published v1 API names and arities exist at production boundary" do
    api = Jason.decode!(File.read!("docs/flywheel/u03/api.json"))

    exported =
      Enum.map(Nano.Flywheel.__info__(:functions), fn {name, arity} -> "#{name}/#{arity}" end)

    assert api["api_version"] == 1
    assert api["schema_version"] == 1
    assert Enum.all?(api["functions"], &(&1 in exported))
    assert "prepare_dispatch/4" in api["functions"]
    assert "reconcile_bootstrap/5" in api["functions"]
  end
end
