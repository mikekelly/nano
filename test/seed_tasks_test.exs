defmodule SeedTasksTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rigel-tasks-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "exit, merged output, env and cwd, durable state", %{root: root} do
    {:ok, h} =
      SeedTasks.start("printf '%s' \"$HELLO\"; pwd; echo err >&2; exit 7",
        root: root,
        cwd: root,
        env: [{"HELLO", "hello"}]
      )

    assert_receive {:seed_task, id, %{status: :exited, exit_code: 7, bytes: bytes}}, 3000
    assert id == h.id
    assert bytes > 0
    assert {:ok, %{status: :exited}} = SeedTasks.status(h)
    assert {:ok, %{output: text, truncated: false}} = SeedTasks.tail(h)
    assert {:ok, %{output: "hello", next_offset: 5, eof: false}} = SeedTasks.read(h, limit: 5)
    assert {:ok, %{output: "", eof: true}} = SeedTasks.read(h, offset: 10000)
    assert {:error, :invalid_limits} = SeedTasks.read(h, limit: 0)
    assert text == "hello#{root}\nerr\n"
    assert {:error, :not_running} = SeedTasks.cancel(h)
  end

  test "timeout and cancel kill descendants", %{root: root} do
    for mode <- [:timeout, :cancel] do
      marker = Path.join(root, Atom.to_string(mode))

      {:ok, h} =
        SeedTasks.start("echo before; (sleep 0.5; touch '#{marker}') & wait",
          root: root,
          timeout: if(mode == :timeout, do: 100, else: 5000)
        )

      if mode == :cancel do
        Process.sleep(50)
        assert :ok = SeedTasks.cancel(h)
      end

      expected = if mode == :timeout, do: :timed_out, else: :cancelled
      assert_receive {:seed_task, _, %{status: ^expected}}, 3000
      Process.sleep(600)
      refute File.exists?(marker)
      assert {:ok, %{output: "before\n"}} = SeedTasks.tail(h)
    end
  end

  test "worker survives starting caller death and bounds large output", %{root: root} do
    parent = self()

    p =
      spawn(fn ->
        {:ok, h} = SeedTasks.start("sleep 0.1; seq 1 10000", root: root, owner: parent)
        send(parent, {:handle, h})
      end)

    monitor = Process.monitor(p)
    assert_receive {:handle, h}
    assert_receive {:DOWN, ^monitor, _, _, _}
    assert_receive {:seed_task, _, %{status: :exited}}, 3000

    assert {:ok, %{output: output, truncated: true, bytes: bytes}} =
             SeedTasks.tail(h, max_bytes: 100, max_lines: 3)

    assert bytes > 10000
    assert byte_size(output) <= 100
    assert output == "9999\n10000\n"
    assert {:ok, %{truncated: true}} = SeedTasks.tail(h, max_bytes: 10)
  end

  test "name delivery waits across owner restart", %{root: root} do
    name = "seed-tasks-test-" <> Path.basename(root)
    {:ok, h} = SeedTasks.start("echo done", root: root, owner: name)
    Process.sleep(200)
    assert {:ok, %{status: :exited}} = SeedTasks.status(h)
    assert :yes = Nano.Names.register_name({:agent, name}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    assert_receive {:seed_task, _, %{status: :exited, bytes: 5}}, 2000
  end

  test "reconciliation marks orphans, replays pending completion, acknowledgment stops replay", %{
    root: root
  } do
    name = "seed-tasks-reconcile-" <> Path.basename(root)
    {:ok, h} = SeedTasks.start("true", root: root, owner: name)
    Process.sleep(100)
    {:ok, state} = SeedTasks.status(h)
    path = Path.join(root, h.id <> ".state")
    orphan = Map.merge(state, %{status: :running, boot_id: :old_vm})
    File.write!(path, :erlang.term_to_binary(orphan))
    assert {:ok, [{:ok, _, :interrupted}]} = SeedTasks.reconcile(root)
    assert {:ok, %{status: :interrupted}} = SeedTasks.status(h)
    assert :yes = Nano.Names.register_name({:agent, name}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    assert_receive {:seed_task, _, %{status: :interrupted}}, 2000
    assert :ok = SeedTasks.ack(h)
    Process.sleep(300)
    # A replay already in flight can arrive before ack; flush at-least-once duplicates.
    flush_events()
    assert {:ok, _} = SeedTasks.reconcile(root)
    refute_receive {:seed_task, _, _}, 400
    assert {:ok, %{pending: false}} = SeedTasks.status(h)
  end

  test "reconcile preserves live workers and repeated cancellation completes once", %{root: root} do
    for _ <- 1..20 do
      {:ok, h} = SeedTasks.start("sleep 5", root: root)
      assert {:error, :not_finished} = SeedTasks.ack(h)
      assert {:ok, _} = SeedTasks.reconcile(root)
      assert {:ok, %{status: status}} = SeedTasks.status(h)
      assert status in [:starting, :running]
      for _ <- 1..10, do: SeedTasks.cancel(h)
      assert_receive {:seed_task, id, %{status: :cancelled}}, 2000
      assert id == h.id
      assert {:error, :not_running} = SeedTasks.cancel(h)
      refute_receive {:seed_task, ^id, _}, 20
    end
  end

  defp flush_events do
    receive do
      {:seed_task, _, _} -> flush_events()
    after
      0 -> :ok
    end
  end

  test "empty output and errors", %{root: root} do
    {:ok, h} = SeedTasks.start("true", root: root)
    assert_receive {:seed_task, _, %{bytes: 0}}, 3000
    assert {:ok, %{output: "", truncated: false}} = SeedTasks.tail(h)
    assert {:error, :invalid_limits} = SeedTasks.tail(h, max_bytes: 0)
    assert {:error, :invalid_command} = SeedTasks.start("", root: root)
    assert {:error, :invalid_timeout} = SeedTasks.start("true", timeout: 0)
    assert {:error, :invalid_env} = SeedTasks.start("true", env: [:bad])
    assert {:error, :enoent} = SeedTasks.status(%{root: root, id: "missing"})
    {:ok, _} = SeedTasks.start("true", root: root, cwd: Path.join(root, "missing"))
    assert_receive {:seed_task, _, %{status: :failed}}, 3000
  end
end
