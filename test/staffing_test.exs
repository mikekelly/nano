defmodule Nano.StaffingTest do
  use ExUnit.Case, async: true
  alias Nano.Staffing

  defp available do
    [
      lookup: fn _ -> {:ok, %{context_length: 272_000}} end,
      check: fn _, "low", 272_000 -> {:ok, %{context_length: 272_000}} end
    ]
  end

  defp temp_path do
    dir =
      Path.join(
        System.tmp_dir!(),
        "staffing-contract-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    Path.join(dir, "matrix.json")
  end

  test "selectors reject contradictions before provider, aliases agree, effective prompt role agrees" do
    for opts <- [
          [level: :exec, stratum: :worker],
          [level: :engineering, model: :exec],
          [level: :exec, model: "openai-codex/gpt-6.1-sol"],
          [model: "openai-codex/gpt-6-astra"],
          [level: "worker"],
          [stratum: :worker, model: 42]
        ] do
      assert {:error, _} = Staffing.resolve(opts ++ available())
    end

    assert {:ok, pair} =
             Staffing.resolve(
               [level: :engineering, stratum: :worker, model: "openai-codex/gpt-6.1-sol"] ++
                 available()
             )

    assert pair.level == :engineering

    {:ok, composed} =
      Delegation.Prompt.compose(
        name: "alias",
        parent: "p",
        level: pair.level,
        job: "Build",
        staffing: pair
      )

    assert composed.prompt =~ "Your level is engineering"
    assert composed.prompt =~ "Staffing: openai-codex/gpt-6.1-sol / low"
    assert {:ok, pair} = Staffing.resolve([model: :exec] ++ available())
    assert pair.level == :exec

    {:ok, composed} =
      Delegation.Prompt.compose(
        name: "exec",
        parent: "p",
        level: pair.level,
        job: "Plan",
        staffing: pair
      )

    assert composed.prompt =~ "Your level is exec"
    assert composed.prompt =~ "Staffing: openai-codex/gpt-6-astra / low"
    assert Enum.any?(composed.provenance.partials, &String.ends_with?(&1.path, "exec.txt"))

    assert {:error, "conflicting staffing strata"} =
             Delegation.subagent("conflict-test",
               parent: "p",
               level: :exec,
               stratum: :worker,
               job: "No launch"
             )
  end

  test "custom matrix is consumed through resolver and delegation, breadcrumb uses actual path" do
    path = temp_path()
    {:ok, data} = Staffing.matrix()
    custom = put_in(data, ["strata", "lead", "model"], "openai-codex/gpt-6-astra")
    assert {:ok, _} = Staffing.refresh(path: path, data: custom)
    assert {:ok, pair} = Staffing.resolve([stratum: :lead, matrix_path: path] ++ available())
    assert pair.model == "openai-codex/gpt-6-astra"
    assert pair.level == :lead

    {:ok, composed} =
      Delegation.Prompt.compose(
        name: "custom",
        parent: "p",
        level: pair.level,
        job: "Review",
        staffing: pair
      )

    assert composed.prompt =~ "Your level is lead"
    assert composed.prompt =~ path
    assert composed.prompt =~ "Staffing: openai-codex/gpt-6-astra / low"
    File.write!(path, "{}")

    assert {:error, reason} =
             Delegation.subagent("matrix-test",
               parent: "p",
               level: :lead,
               matrix_path: path,
               job: "No launch"
             )

    assert reason =~ "invalid bounded staffing matrix"
    assert NanoAgent.whereis("matrix-test") == nil
  end

  test "invalid evidence and mappings cannot replace existing candidate" do
    path = temp_path()
    {:ok, data} = Staffing.matrix()
    {:ok, _} = Staffing.refresh(path: path, data: data)
    before = File.read!(path)

    bads = [
      put_in(data, ["strata", "worker", "model"], "unproven/model"),
      put_in(data, ["strata", "worker", "effort"], "high"),
      put_in(data, ["sources", Access.at(0), "sha256"], "not-a-hash"),
      put_in(data, ["sources", Access.at(0), "url"], "not a URL"),
      put_in(data, ["sources", Access.at(0), "fetched_at"], "yesterday"),
      put_in(data, ["pairs", Access.at(0), "reference_source_index"], 8),
      put_in(data, ["pairs", Access.at(0), "model"], ""),
      put_in(
        data,
        ["pairs", Access.at(0), "reference_metrics", "cost_per_index_task_usd"],
        "free"
      ),
      put_in(data, ["pairs", Access.at(0), "reference_metrics", "cost_per_index_task_usd"], -1),
      put_in(
        data,
        ["pairs", Access.at(0), "reference_metrics", "terminal_bench_4.0_percent"],
        101
      ),
      put_in(data, ["pairs", Access.at(0), "node_metrics", "speed"], %{}),
      Map.put(data, "pairs", data["pairs"] ++ data["pairs"]),
      put_in(data, ["sources", Access.at(0), "quote"], String.duplicate("x", 4097)),
      Map.put(data, "sources", List.duplicate(hd(data["sources"]), 9)),
      Map.put(data, "pairs", List.duplicate(hd(data["pairs"]), 17)),
      Map.put(data, "dated", 2026)
    ]

    for bad <- bads do
      assert {:error, _} = Staffing.refresh(path: path, data: bad)
      assert File.read!(path) == before
    end

    File.write!(path, String.duplicate("x", 65537))
    assert {:error, reason} = Staffing.matrix(matrix_path: path)
    assert reason =~ "64 KiB"
    assert {:error, _} = Staffing.matrix(matrix_path: 42)
    assert {:error, _} = Staffing.refresh(path: path, data: {:invalid, make_ref()})
  end

  test "future mapped effort is structural data, still must pass actual provider check" do
    path = temp_path()
    {:ok, data} = Staffing.matrix()

    future =
      data
      |> put_in(["pairs", Access.at(0), "effort"], "high")
      |> put_in(["strata", "exec", "effort"], "high")

    assert {:ok, _} = Staffing.refresh(path: path, data: future)
    assert {:ok, %{effort: "high"}} = Staffing.mapping(:exec, matrix_path: path)

    opts = [
      matrix_path: path,
      lookup: fn _ -> {:ok, %{context_length: 272_000}} end,
      check: fn _, effort, _ ->
        assert effort == "high"
        {:error, :unsupported_or_not_allowed}
      end
    ]

    assert {:error, :unsupported_or_not_allowed} = Staffing.select(:exec, opts)
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

    assert {:ok, %{review_required: true, validation: :structural_only}} =
             Staffing.refresh(path: path, data: data)

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
