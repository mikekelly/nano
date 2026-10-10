defmodule Nano.Flywheel.U06.QueueTest do
  use ExUnit.Case, async: false
  alias Nano.ContextAdmission, as: Admission

  defp push(q, record, root, id \\ "agent", gen \\ 1),
    do: Admission.queue_push(q, record, root, id, gen)

  defp peek(q, root, id \\ "agent", gen \\ 1), do: Admission.queue_peek(q, root, id, gen)

  defp path(root, gen \\ 1, index \\ 1),
    do: Path.join([root, "agent", "pending-v2", "#{gen}-#{index}.term"])

  defp record(text \\ "original"), do: %{text: text, images: [], evidence: %{}}

  test "bounded authority-bound FIFO retains files, rejects collisions and finite limits" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "u06-queue")
    original = record()
    {:ok, q} = push(Admission.empty_queue("agent", 1), original, root)
    assert {:ok, ^original, next} = peek(q, root)
    assert next.count == 0 and next.bytes == 0 and next.items == %{}
    assert File.regular?(path(root))
    assert {:ok, ^original, ^next} = peek(q, root)
    assert {:error, _} = push(Admission.empty_queue("agent", 1), record("different"), root)
    assert {:ok, ^original, ^next} = peek(q, root)
    assert {:error, _} = push(nil, original, root)
    items = Map.new(1..10_000, &{&1, %{sha256: String.duplicate("0", 64), bytes: 10}})

    assert {:error, _} =
             push(%{q | count: 10_000, write_index: 10_000, items: items}, original, root)

    assert {:error, _} = push(%{q | bytes: 67_108_864}, original, root)
    assert {:error, _} = push(q, record(String.duplicate("x", 1_048_576)), root)
    File.rm!(path(root))
    assert {:error, :unavailable_pending_backlog} = peek(q, root)
  end

  test "coherent expected raw digest detects same-size valid ETF corruption" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "u06-queue-corrupt")
    {:ok, q} = push(Admission.empty_queue("agent", 1), record(), root)
    bytes = File.read!(path(root))
    changed = :binary.replace(bytes, "original", "tampered")
    assert byte_size(changed) == byte_size(bytes)
    assert :erlang.binary_to_term(changed).record.text == "tampered"
    File.write!(path(root), changed)
    assert {:error, :unavailable_pending_backlog} = peek(q, root)
    # A self-reported replacement cannot advance original envelope authority.
    assert q.read_index == 1 and q.count == 1
    File.write!(path(root), bytes)
    assert {:ok, %{text: "original"}, _} = peek(q, root)
  end

  test "agent lifecycle and index associations remain bound outside replaceable records" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "u06-queue-identity")
    {:ok, q} = push(Admission.empty_queue("agent", 1), record(), root)
    assert {:error, _} = peek(q, root, "other-agent", 1)
    assert {:error, _} = peek(q, root, "agent", 2)
    original = path(root) |> File.read!() |> :erlang.binary_to_term()

    for changed <- [
          %{original | agent_id: "other"},
          %{original | lifecycle_generation: 2},
          %{original | index: 2}
        ] do
      bytes = :erlang.term_to_binary(changed)
      File.write!(path(root), bytes)
      assert {:error, :unavailable_pending_backlog} = peek(q, root)
      # Independently exercise identity fencing even with a fixture-authorized digest:
      # matching raw bytes alone cannot associate a foreign ID/lifecycle/index.
      entry = %{
        sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        bytes: byte_size(bytes)
      }

      associated = %{q | items: %{1 => entry}, bytes: byte_size(bytes)}
      assert {:error, :unavailable_pending_backlog} = peek(associated, root)
    end

    v1 = %{version: 1, read_index: 1, write_index: 1, count: 1, bytes: 1}
    assert {:error, :empty_or_unbound_pending_backlog} = peek(v1, root)
  end

  test "uncertain publication never advances coherent expected pointer/digest" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "u06-queue-fault")

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :before_directory_sync and path =~ "/pending-v2/",
        do: {:error, :injected},
        else: :ok
    end)

    on_exit(fn -> Application.delete_env(:nano, :state_store_fault) end)
    q = Admission.empty_queue("agent", 1)
    assert {:error, :injected} = push(q, record(), root)
    assert q.count == 0 and q.items == %{}
  end
end
