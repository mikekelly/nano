defmodule Seedling.MemoryDecisionTest do
  use ExUnit.Case, async: false
  alias Seedling.{Memory, Decision}

  setup do
    dir = Path.join(System.tmp_dir!(), "memory-test-#{System.unique_integer([:positive])}")
    old = Application.get_env(:nano, :memory_dir)
    Application.put_env(:nano, :memory_dir, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :memory_dir, old),
        else: Application.delete_env(:nano, :memory_dir)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "durable isolated graph and bounded retrieval" do
    assert {:ok, a} =
             Memory.add("a", "Alice prefers tea", source_session: "s1", tags: ["preference"])

    assert {:ok, b} = Memory.add("a", "Buy it on Tuesday", links: [a["id"]])
    assert {:ok, _} = Memory.add("b", "Alice prefers coffee")
    assert {:ok, [first, second]} = Memory.retrieve("a", "Alice tea")
    assert first == a
    assert second == b
    assert first["source_session"] == "s1"
    assert {:ok, [^a]} = Memory.retrieve("a", "Alice tea", budget: byte_size(a["text"]))
    assert {:ok, []} = Memory.retrieve("a", "unrelated")
    assert {:ok, []} = Memory.retrieve("a", "tea", budget: 0)
    assert {:ok, nodes} = Memory.all("a")
    assert length(nodes) == 2
    assert {:error, :unknown_link} = Memory.add("a", "no", links: ["missing"])
    assert {:error, :invalid_memory} = Memory.add("a", "")
    assert {:error, :invalid_retrieval} = Memory.retrieve("a", "x", limit: -1)
  end

  test "concurrent updates are not lost" do
    tasks = for i <- 1..12, do: Task.async(fn -> Memory.add("same", "Fact #{i}") end)
    assert Enum.all?(Task.await_many(tasks), &match?({:ok, _}, &1))
    assert {:ok, nodes} = Memory.all("same")
    assert length(nodes) == 12
  end

  test "corrupt stores do not get overwritten", %{dir: dir} do
    {:ok, _} = Memory.add("a", "fact")
    [file] = Path.wildcard(Path.join(dir, "*.json"))
    File.write!(file, "bad")
    assert {:error, :corrupt_memory_store} = Memory.all("a")
    assert {:error, :corrupt_memory_store} = Memory.add("a", "new")
    assert File.read!(file) == "bad"
  end

  test "typed decisions and schema request" do
    for {task, data} <- [
          route: %{"bot_ids" => ["a"]},
          memory: %{"memory_ids" => ["m"]},
          compact: %{"compact" => true},
          summarize: %{
            "summary" => "Decision: ship. Commitment: Alice tests. Preference: tea. Open: date?"
          }
        ] do
      adapter = fn request ->
        assert request["response_format"]["json_schema"]["strict"]
        assert request["provider"]["require_parameters"]
        assert request["max_tokens"] == 100
        assert request["model"] == "fake"
        {:ok, %{"confidence" => 0.8, "data" => data}}
      end

      assert {:ok, %{confidence: 0.8, data: ^data}} =
               Decision.decide(task, %{transcript: "sample"},
                 adapter: adapter,
                 model: "fake",
                 max_tokens: 100
               )
    end

    for result <- [
          %{"confidence" => 2, "data" => %{"compact" => true}},
          %{"confidence" => 0.2, "data" => %{"compact" => "yes"}},
          %{"confidence" => 0.2, "data" => %{"compact" => true}, "extra" => 1}
        ] do
      assert {:error, _} = Decision.decide(:compact, %{}, adapter: fn _ -> {:ok, result} end)
    end

    assert {:error, :invalid_input_or_output} = Decision.decide(:unknown, %{})

    assert {:error, :offline} =
             Decision.decide(:route, %{}, adapter: fn _ -> {:error, :offline} end)

    assert {:error, _} = Decision.decide(:route, %{}, adapter: fn _ -> raise "offline" end)
  end

  test "model-assisted graph selection validates candidate IDs" do
    {:ok, node} = Memory.add("a", "Alice likes tea")
    adapter = fn _ -> {:ok, %{"confidence" => 0.9, "data" => %{"memory_ids" => [node["id"]]}}} end

    assert {:ok, [^node]} =
             Memory.retrieve("a", "tea", decision: true, decision_opts: [adapter: adapter])

    bad = fn _ -> {:ok, %{"confidence" => 0.9, "data" => %{"memory_ids" => ["foreign"]}}} end

    assert {:error, :unknown_memory_id} =
             Memory.retrieve("a", "tea", decision: true, decision_opts: [adapter: bad])
  end
end
