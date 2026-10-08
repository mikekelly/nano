defmodule MemoryTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "deneb-memory-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root]}
  end

  test "durable JSON primitives and owner isolation", %{opts: opts} do
    assert {:error, :not_found} = Memory.get("a", "k", opts)
    assert {:ok, %{"a" => 1}} = Memory.put("a", "k", %{a: 1}, opts)
    assert {:ok, %{"a" => 1}} = Task.async(fn -> Memory.get("a", "k", opts) end) |> Task.await()
    assert {:ok, %{}} = Memory.list("b", opts)
    assert :ok = Memory.delete("a", "k", opts)
    assert {:ok, %{}} = Memory.list("a", opts)
  end

  test "concurrent updates never lose increments", %{opts: opts} do
    1..40
    |> Task.async_stream(fn _ -> Memory.update("a", "n", 0, &{:ok, &1 + 1}, opts) end,
      max_concurrency: 10
    )
    |> Enum.to_list()

    assert {:ok, 40} = Memory.get("a", "n", opts)
    assert {:error, :refused} = Memory.update("a", "n", 0, fn _ -> {:error, :refused} end, opts)
    assert {:ok, 40} = Memory.get("a", "n", opts)
  end

  test "rejects unsafe data and preserves previous value", %{opts: opts} do
    assert {:ok, 1} = Memory.put("../owner", "k", 1, opts)
    assert {:error, :not_json_encodable} = Memory.put("../owner", "k", self(), opts)

    assert {:error, :memory_too_large} =
             Memory.put("../owner", "k", String.duplicate("a", 1_000_001), opts)

    assert {:ok, 1} = Memory.get("../owner", "k", opts)
    assert {:error, :invalid_name} = Memory.put("", "k", 1, opts)
    assert {:error, :invalid_name} = Memory.get("a", "", opts)
  end

  test "corruption is reported not overwritten", %{opts: opts} do
    Memory.put("a", "k", 1, opts)
    [path] = Path.wildcard(opts[:root] <> "/*.json")
    File.write!(path, "invalid")
    assert {:error, _} = Memory.list("a", opts)
    assert {:error, _} = Memory.put("a", "k", 2, opts)
    assert File.read!(path) == "invalid"
  end
end
