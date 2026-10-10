defmodule Nano.Flywheel.U06.QueueTest do
  use ExUnit.Case, async: false
  alias Nano.ContextAdmission, as: Admission

  test "bounded durable FIFO preserves pointer and refuses malformed, unavailable and saturated records" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "u06-queue")
    record = %{text: "<event seq=\"1\">pending</event>", images: [], evidence: %{}}
    {:ok, q} = Admission.queue_push(Admission.empty_queue(), record, root, "agent")
    assert {:ok, ^record, next} = Admission.queue_peek(q, root, "agent")
    assert next.count == 0 and next.bytes == 0
    assert File.regular?(Path.join([root, "agent", "pending-v1", "1.term"]))
    # Pointer can be restored without deleting authority/evidence.
    assert {:ok, ^record, ^next} = Admission.queue_peek(q, root, "agent")

    assert {:error, _} =
             Admission.queue_push(
               Admission.empty_queue(),
               %{record | text: "different newer bytes"},
               root,
               "agent"
             )

    assert {:ok, ^record, ^next} = Admission.queue_peek(q, root, "agent")
    assert {:error, _} = Admission.queue_push(nil, record, root, "agent")

    assert {:error, _} =
             Admission.queue_push(
               %{q | count: 10_000, write_index: 10_000},
               record,
               root,
               "agent"
             )

    assert {:error, _} = Admission.queue_push(%{q | bytes: 67_108_864}, record, root, "agent")

    assert {:error, _} =
             Admission.queue_push(
               q,
               %{record | text: String.duplicate("x", 1_048_576)},
               root,
               "agent"
             )

    File.rm!(Path.join([root, "agent", "pending-v1", "1.term"]))
    assert {:error, :unavailable_pending_backlog} = Admission.queue_peek(q, root, "agent")
  end

  test "uncertain queue publication does not advance pointer" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "u06-queue-fault")

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :before_directory_sync and path =~ "/pending-v1/",
        do: {:error, :injected},
        else: :ok
    end)

    on_exit(fn -> Application.delete_env(:nano, :state_store_fault) end)
    q = Admission.empty_queue()

    assert {:error, :injected} =
             Admission.queue_push(q, %{text: "event", images: [], evidence: %{}}, root, "agent")

    assert q.count == 0
  end
end
