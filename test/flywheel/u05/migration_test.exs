defmodule Nano.Flywheel.U05.MigrationTest do
  use ExUnit.Case, async: false
  alias Nano.StateStore, as: Store

  setup do
    old = Application.fetch_env!(:nano, :state_dir)

    private =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "u05-migration-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(private)
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    Application.put_env(:nano, :state_dir, private)

    on_exit(fn ->
      Application.delete_env(:nano, :state_store_fault)
      Supervisor.terminate_child(Nano.Supervisor, Store)
      Application.put_env(:nano, :state_dir, old)
      Supervisor.restart_child(Nano.Supervisor, Store)
    end)

    %{dir: private}
  end

  defp start_store, do: Supervisor.restart_child(Nano.Supervisor, Store)

  defp restart do
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    {:ok, _} = start_store()
  end

  defp write(path, value), do: File.write!(path, :erlang.term_to_binary(value))

  test "A4 embedded legacy pair migrates once; split/missing legacy bindings remain unavailable",
       c do
    coherent = %{
      name: "legacy",
      id: "legacy-id",
      pid: self(),
      pending: [:retained_evidence],
      bindings: [value: 41]
    }

    split = %{name: "split", id: "split-id", pid: self()}
    write(Path.join(c.dir, "legacy.term"), coherent)
    write(Path.join(c.dir, "split.term"), split)
    write(Path.join(c.dir, "split.bindings"), {[value: 999], []})
    original = File.read!(Path.join(c.dir, "legacy.term"))
    {:ok, _} = start_store()
    assert Store.get("legacy") == Map.delete(coherent, :bindings)
    assert Store.bindings("legacy") == {[value: 41], []}
    assert Store.get("split") == nil
    assert Store.binding_status("split") == :unavailable
    assert {:error, :recovery_unavailable} = Store.register("split", "split-id", self())
    assert File.read!(Path.join(c.dir, "legacy.term")) == original
    # An unversioned split file cannot establish identity/revision coherence.
    assert File.exists?(Path.join(c.dir, "split.bindings"))
    assert :ok = Store.delete("legacy")
    restart()
    assert Store.get("legacy") == nil
    assert {:error, :deleted} = Store.register("legacy", "legacy-id", self())
    assert File.read!(Path.join(c.dir, "legacy.term")) == original
  end

  test "A4 forward mutation/checkpoint restoration retains latest lifecycle/tombstone and pending evidence",
       c do
    {:ok, _} = start_store()
    {:ok, old} = Store.register("restored", "old-id", self())
    metadata = %{name: "restored", id: old.id, pid: self(), pending: [:first]}
    assert {:ok, %{status: :durable}} = Store.checkpoint(old, 1, metadata, value: 1)
    # Forward mutation then deletion/replacement creates newer authority than old code/checkpoint.
    assert {:ok, _} = Store.checkpoint(old, 2, %{metadata | pending: [:new_evidence]}, value: 2)
    assert :ok = Store.delete("restored")
    {:ok, current} = Store.register("restored", "new-id", self())
    assert current.lifecycle_generation > old.lifecycle_generation

    assert {:error, :bindings_unavailable} =
             Store.checkpoint(current, 3, %{metadata | id: current.id}, :unchanged)

    metadata = %{name: "restored", id: current.id, pid: self(), pending: [:must_survive]}
    assert {:ok, _} = Store.checkpoint(current, 3, metadata, value: 3)
    checkpoint = Path.join(c.dir, "preserved")
    File.mkdir_p!(checkpoint)

    for file <- File.ls!(c.dir),
        file != "preserved",
        do: File.cp!(Path.join(c.dir, file), Path.join(checkpoint, file))

    # Allowed restoration in a disposable copy: latest whole coherent directory, never old source.
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    Application.put_env(:nano, :state_dir, checkpoint)
    {:ok, _} = start_store()
    assert {:error, :retired_identity} = Store.register("restored", "old-id", self())
    assert Store.get("restored") == metadata
    assert Store.bindings("restored") == {[value: 3], []}
    assert {:error, :stale} = Store.checkpoint(old, 99, %{metadata | id: old.id}, value: -1)
    {:ok, restored} = Store.register("restored", "new-id", self())
    assert restored.lifecycle_generation == current.lifecycle_generation
    assert restored.store_generation != current.store_generation

    assert {:ok, _} =
             Store.checkpoint(restored, 4, metadata, :unchanged)
             |> then(fn result ->
               # First registration after restart must resave bindings, not assume an empty cache.
               assert result == {:error, :bindings_unavailable}
               Store.checkpoint(restored, 4, metadata, value: 3)
             end)

    assert :ok = Store.delete("restored")
    restart()
    assert Store.get("restored") == nil
    assert {:error, :deleted} = Store.register("restored", "new-id", self())
  end

  test "A4 orphan newer blob never combines with older envelope; corrupt selected blob unavailable",
       c do
    {:ok, _} = start_store()
    {:ok, token} = Store.register("pair", "pair-id", self())
    metadata = %{name: "pair", id: token.id, pid: self(), pending: [:old]}
    {:ok, _} = Store.checkpoint(token, 1, metadata, value: 1)

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :before_rename and String.ends_with?(path, ".envelope-v1"),
        do: {:error, :injected},
        else: :ok
    end)

    assert {:ok, %{status: :memory_only}} =
             Store.checkpoint(token, 2, %{metadata | pending: [:new]}, value: 2)

    Application.delete_env(:nano, :state_store_fault)
    restart()
    assert Store.get("pair").pending == [:old]
    assert Store.bindings("pair") == {[value: 1], []}
    envelope = Path.join(c.dir, "pair.envelope-v1") |> File.read!() |> :erlang.binary_to_term()
    File.write!(Path.join(c.dir, envelope.blob), "corrupt")
    restart()
    assert Store.get("pair") == nil
    assert Store.bindings("pair") == :unavailable
    assert {:error, :recovery_unavailable} = Store.register("pair", "pair-id", self())
  end

  test "R1 F2 missing authority after v1 cutover never resurrects preserved legacy", c do
    legacy = %{
      name: "victim",
      id: "old-id",
      pid: self(),
      pending: [:evidence],
      bindings: [secret: 41]
    }

    write(Path.join(c.dir, "victim.term"), legacy)
    {:ok, _} = start_store()
    assert Store.bindings("victim") == {[secret: 41], []}
    assert :ok = Store.delete("victim")
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    authority = Path.join(c.dir, "lifecycle-v1.term")
    preserved = File.read!(authority)
    File.rm!(authority)
    before = Map.new(File.ls!(c.dir), fn f -> {f, File.read!(Path.join(c.dir, f))} end)
    {:ok, _} = start_store()
    assert Store.availability() != :ok
    assert Store.get("victim") == nil
    assert {:error, _} = Store.register("victim", "old-id", self())
    assert before == Map.new(File.ls!(c.dir), fn f -> {f, File.read!(Path.join(c.dir, f))} end)
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    File.write!(authority, preserved)
    {:ok, _} = start_store()
    assert {:error, :deleted} = Store.register("victim", "old-id", self())
    assert Store.get("victim") == nil
  end
end
