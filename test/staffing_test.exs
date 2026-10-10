defmodule Nano.StaffingTest do
  use ExUnit.Case, async: true
  alias Nano.Staffing

  defp available do
    [
      lookup: fn _ -> {:ok, %{context_length: 272_000}} end,
      check: fn _, "low", 272_000 -> {:ok, %{context_length: 272_000}} end
    ]
  end

  test "strata and engineering alias keep operator pairs and effort" do
    for stratum <- [:lead, :worker, :grunt, :engineering] do
      assert {:ok, %{model: "openai-codex/gpt-6.1-sol", effort: "low", max_context: 272_000}} =
               Staffing.select(stratum, available())
    end

    assert {:ok, %{model: "openai-codex/gpt-6-astra"}} = Staffing.select(:exec, available())
    assert {:error, _} = Staffing.select(:exec, available() ++ [effort: "high"])
    assert {:error, _} = Staffing.select(:bogus, available())
    assert {:ok, "openai-codex/gpt-6.1-sol"} = Delegation.model(:engineering)
  end

  test "unavailable provider and forbidden pair propagate without fallback" do
    assert {:error, :unavailable} =
             Staffing.select(:worker, lookup: fn _ -> {:error, :unavailable} end)

    opts = Keyword.put(available(), :check, fn _, _, _ -> {:error, :forbidden} end)
    assert {:error, :forbidden} = Staffing.select(:exec, opts)
    assert {:error, :forbidden} = Staffing.select("other/model", opts)
  end

  test "dated provenance, exact-node unknowns, reference effort and numbers" do
    assert {:ok, data} = Staffing.matrix()
    assert data["dated"] == "2026-10-10"
    assert [%{"url" => url, "sha256" => hash}] = data["sources"]
    assert url =~ "sol-low-vs-gpt-6-astra-low"
    assert byte_size(hash) == 64

    for pair <- data["pairs"] do
      assert pair["effort"] == "low"
      assert pair["node_metrics"]["cost_per_task"] == nil
      assert pair["unknown_reason"] =~ "ChatGPT"
      assert pair["reference_metrics"]["cost_per_index_task_usd"] > 0
    end
  end

  test "reviewed refresh atomically persists, invalid candidate leaves file intact" do
    dir = Path.join(System.tmp_dir!(), "staffing-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "matrix.json")
    {:ok, data} = Staffing.matrix()
    assert {:ok, %{review_required: false}} = Staffing.refresh(path: path, data: data)
    before = File.read!(path)
    assert {:error, _} = Staffing.refresh(path: path, data: %{})
    assert File.read!(path) == before
    assert {:ok, ^data} = Staffing.matrix(matrix_path: path)
  end

  test "startup rejects unavailable selection before any worktree or child" do
    name = "staffing-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    assert {:error, _} =
             Delegation.subagent(name, parent: "absent", level: :worker, job: "No model call")

    assert NanoAgent.whereis(name) == nil
  end

  test "staffing breadcrumb preserves full seed composition" do
    {:ok, pair} = Staffing.select(:worker, available())

    {:ok, composed} =
      Delegation.Prompt.compose(
        name: "x",
        parent: "p",
        level: :worker,
        job: "Build",
        staffing: pair
      )

    seed = File.read!(Path.expand("../prompts/seed.txt", __DIR__))
    assert String.starts_with?(composed.prompt, seed)
    assert composed.prompt =~ "Nano.Staffing"
    assert composed.prompt =~ "preserving this composition rule"
  end
end
