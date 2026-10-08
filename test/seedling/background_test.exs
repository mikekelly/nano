defmodule Seedling.BackgroundTest do
  use ExUnit.Case, async: false
  alias Seedling.Background, as: Background
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "orion-bg-#{suffix}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, owner: "bg-owner-#{suffix}"}
  end

  defp eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("condition did not become true")

        Process.sleep(10)
        poll(fun, deadline)
    end
  end

  defp start_job(ctx, command, opts \\ []) do
    {:ok, job, id} = Background.start(command, [owner: ctx.owner, root: ctx.root] ++ opts)

    on_exit(fn ->
      if Process.alive?(job) do
        Background.cancel(job)
        # Usually completed or killed within 20ms; allow startup handshake under load.
        eventually(fn ->
          case Background.info(job) do
            %{status: :running} -> false
            _ -> true
          end
        end)

        if Process.alive?(job), do: GenServer.stop(job)
      end
    end)

    {job, id}
  end

  defp finished(job) do
    eventually(fn ->
      case Background.info(job) do
        %{status: status} = info when is_integer(status) -> info
        _ -> false
      end
    end)
  end

  defp gated(ctx, prefix \\ "echo first") do
    release = Path.join(ctx.root, "release")

    command =
      prefix <>
        "; while [ ! -f " <>
        Seedling.Tools.quote_arg(release) <> " ]; do sleep 0.02; done; echo last"

    {command, release}
  end

  defp start_agent(name) do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    {:ok, agent} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(name)
    end)

    {agent, model}
  end

  test "waits for all foreground output, records metadata and numeric exit", ctx do
    {command, release} = gated(ctx)
    {job, id} = start_job(ctx, command)
    info = Background.info(job)
    assert info.status == :running
    assert info.owner == ctx.owner
    eventually(fn -> File.read(info.output) == {:ok, "first\n"} end)
    assert Background.info(job).status == :running
    File.write!(release, "")
    info = finished(job)
    assert info.status == 0
    assert info.reason == :exit
    assert info.errors == []

    assert {:ok, %{text: "first\nlast\n", bytes: 11, truncated: false}} =
             Background.tail(info.output)

    assert %{"status" => 0, "owner" => owner} =
             Jason.decode!(File.read!(Path.join([ctx.root, ctx.owner, id, "result.json"])))

    assert owner == ctx.owner
    assert File.exists?(Path.join([ctx.root, ctx.owner, id, "metadata.json"]))
  end

  test "completed results can be recovered by name and ID without a live worker", ctx do
    {command, release} = gated(ctx)
    {job, id} = start_job(ctx, command)
    assert {:error, :enoent} = Background.result(ctx.owner, id, root: ctx.root)
    File.write!(release, "")
    assert finished(job).status == 0
    GenServer.stop(job)

    assert {:ok, %{"status" => 0, "reason" => "exit", "output" => output}} =
             Background.result(ctx.owner, id, root: ctx.root)

    assert {:ok, %{text: "first\nlast\n"}} = Background.tail(output)
    assert {:error, :invalid_owner} = Background.result("..", id, root: ctx.root)
    assert {:error, :invalid_id} = Background.result(ctx.owner, "../escape", root: ctx.root)
    assert {:error, :invalid_options} = Background.result(ctx.owner, id, %{})
    assert {:error, :unknown_option} = Background.result(ctx.owner, id, weird: true)
    path = Path.join([ctx.root, ctx.owner, id, "result.json"])
    File.write!(path, "invalid json")
    assert {:error, :invalid_result} = Background.result(ctx.owner, id, root: ctx.root)
    File.write!(path, String.duplicate("x", 64_001))
    assert {:error, :result_too_large} = Background.result(ctx.owner, id, root: ctx.root)
  end

  test "working directory, environment, stderr and nonzero exit", ctx do
    {job, _} =
      start_job(ctx, "printf '%s\\n' \"$BG_VALUE\"; pwd; echo err >&2; exit 7",
        cwd: ctx.root,
        env: [{"BG_VALUE", "quoted ' value"}, {"PATH", "/no/commands/here"}],
        timeout: :infinity
      )

    info = finished(job)
    assert info.status == 7
    assert info.reason == :exit
    assert {:ok, %{text: text}} = Background.tail(info.output)
    assert text == "quoted ' value\n#{ctx.root}\nerr\n"
  end

  test "timeout kills the actual shell group, including its child", ctx do
    child_path = Path.join(ctx.root, "child.pid")

    command =
      "sleep 60 & echo $! > " <> Seedling.Tools.quote_arg(child_path) <> "; wait; echo bad"

    {job, _} = start_job(ctx, command, timeout: 500)
    eventually(fn -> File.exists?(child_path) end)
    child = child_path |> File.read!() |> String.trim() |> String.to_integer()
    info = finished(job)
    assert info.reason == :timeout
    assert info.status != 0
    assert is_integer(info.session_pid)
    assert info.session_pid != info.os_pid
    # A killed child may remain a zombie until this container's PID 1 reaps it.
    eventually(fn ->
      case File.read("/proc/#{child}/stat") do
        {:error, :enoent} -> true
        {:ok, stat} -> String.contains?(stat, ") Z ")
        _ -> false
      end
    end)

    assert {:ok, %{text: text}} = Background.tail(info.output)
    refute text =~ "bad"
  end

  test "zero timeout cancels during the session startup handshake", ctx do
    {job, _} = start_job(ctx, "echo bad", timeout: 0)
    info = finished(job)
    assert info.reason == :timeout
    assert info.status != 0
    assert {:ok, %{text: text}} = Background.tail(info.output)
    refute text =~ "bad"
  end

  test "immediate cancellation is sticky and does not guess the port PID group", ctx do
    for n <- 1..8 do
      {job, _} = start_job(%{ctx | owner: "#{ctx.owner}-#{n}"}, "sleep 60; echo bad")
      assert :ok = Background.cancel(job)
      assert :ok = Background.cancel(job)
      send(job, :timeout)
      info = finished(job)
      assert info.reason == :cancelled
      assert info.status != 0
      assert is_integer(info.session_pid)
      assert {:ok, %{text: text}} = Background.tail(info.output)
      refute text =~ "bad"
    end
  end

  test "unlinked worker and port survive caller death", ctx do
    parent = self()

    caller =
      spawn(fn ->
        send(parent, Background.start("sleep 60", owner: ctx.owner, root: ctx.root))

        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(caller)
    assert_receive {:ok, job, _}

    on_exit(fn ->
      Background.cancel(job)
      if Process.alive?(job), do: GenServer.stop(job)
    end)

    assert {:links, links} = Process.info(job, :links)
    refute caller in links
    assert Enum.any?(links, &is_port/1)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert Process.alive?(job)
    assert :ok = Background.cancel(job)
    assert finished(job).reason == :cancelled
  end

  test "cancel after completion is harmless; late timer cannot change result", ctx do
    {job, _} = start_job(ctx, "exit 3")
    assert finished(job).status == 3
    assert :ok = Background.cancel(job)
    send(job, :timeout)
    assert Background.info(job).reason == :exit
    assert Background.info(job).status == 3
  end

  test "invalid inputs, filesystem failures and dead worker return errors", ctx do
    for {command, opts} <- [
          {nil, []},
          {"x", %{}},
          {"x", [owner: "../escape"]},
          {"x", [owner: ".."]},
          {"x", [owner: ctx.owner, timeout: -1]},
          {"x", [owner: ctx.owner, env: [{"X", nil}]]},
          {"x", [owner: ctx.owner, env: [{"X=bad", "v"}]]},
          {"x", [owner: ctx.owner, weird: true]},
          {"x" <> <<0>>, [owner: ctx.owner]}
        ],
        do: assert(match?({:error, _}, Background.start(command, opts)))

    assert {:error, {:startup, :enoent}} =
             Background.start("true",
               owner: ctx.owner,
               root: ctx.root,
               cwd: Path.join(ctx.root, "missing")
             )

    blocker = Path.join(ctx.root, "file")
    File.write!(blocker, "x")
    assert {:error, {:startup, _}} = Background.start("true", owner: ctx.owner, root: blocker)

    assert {:error, {:startup, :cwd_not_directory}} =
             Background.start("true", owner: ctx.owner, cwd: blocker, root: ctx.root)

    assert {:error, :invalid_pid} = Background.info(nil)
    assert {:error, :invalid_pid} = Background.cancel(:missing)
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    assert {:error, :not_found} = Background.info(dead)
    assert {:error, :not_found} = Background.cancel(dead)
    assert {:error, :enoent} = Background.tail(Path.join(ctx.root, "missing"))
    assert {:error, :eisdir} = Background.tail(ctx.root)

    for opts <- [[bytes: 0], [bytes: 1_000_001], [lines: -1], [before: -1], [bad: 1], %{}],
        do: assert(match?({:error, _}, Background.tail(blocker, opts)))
  end

  test "tail bounds bytes and lines, announces truncation, and pages backwards", ctx do
    path = Path.join(ctx.root, "tail")
    File.write!(path, "one\ntwo\nthree\nfour\n")
    assert {:ok, last} = Background.tail(path, lines: 2)
    assert last.text == "three\nfour\n"
    assert last.truncated
    refute last.partial_first_line
    assert {:ok, first} = Background.tail(path, before: last.next_before, lines: 2)
    assert first.text == "one\ntwo\n"
    assert first.next_before == nil
    assert {:ok, cut} = Background.tail(path, bytes: 3)
    assert cut.text == "ur\n"
    assert cut.bytes == 3
    assert cut.partial_first_line
    assert {:error, {:offset_past_end, 19}} = Background.tail(path, before: 20)
    File.write!(path, "")

    assert {:ok, %{text: "", bytes: 0, truncated: false, next_before: nil}} =
             Background.tail(path)

    File.write!(path, "αβγδε")

    assert {:ok, %{text: text, bytes: 5, partial_first_line: true}} =
             Background.tail(path, bytes: 5)

    assert byte_size(text) == 5
    File.write!(path, "a\nb\nc")
    assert {:ok, %{text: "b\nc", partial_first_line: false}} = Background.tail(path, lines: 2)
    raw = <<255, 0, 254, 10>>
    File.write!(path, raw)
    assert {:ok, %{text: ^raw, bytes: 4, truncated: false}} = Background.tail(path)
  end

  test "large sparse output needs only the bounded suffix, not a whole-file read", ctx do
    path = Path.join(ctx.root, "large")
    {:ok, file} = :file.open(String.to_charlist(path), [:write, :binary, :raw])
    {:ok, _} = :file.position(file, 128 * 1024 * 1024)
    :ok = :file.write(file, "\nerror one\nerror two\n")
    :ok = :file.close(file)
    assert {:ok, page} = Background.tail(path, lines: 2, bytes: 100)
    assert page.text == "error one\nerror two\n"
    assert page.total_bytes > 128 * 1024 * 1024
    assert page.bytes < 100
    assert page.truncated
    refute page.partial_first_line
  end

  test "storage errors after launch are observable and do not crash the job", ctx do
    {command, release} = gated(ctx)
    {job, _} = start_job(ctx, command)
    info = Background.info(job)
    eventually(fn -> File.read(info.output) == {:ok, "first\n"} end)
    File.mkdir_p!(Path.join(Path.dirname(info.output), "result.json.tmp"))
    File.write!(release, "")
    assert %{status: 0, errors: errors} = finished(job)
    assert Enum.any?(errors, &(&1.operation == :persist))
    assert Process.alive?(job)
  end

  test "unexpected port closure kills the known session and reports an error", ctx do
    {job, _} = start_job(ctx, "sleep 60")
    eventually(fn -> Background.info(job).phase == :running end)
    %{port: port} = :sys.get_state(job)
    assert Port.close(port)
    info = finished(job)
    assert info.reason == :error
    assert info.status == 125
    assert Enum.any?(info.errors, &(&1.operation == :port_exit))
  end

  test "a reused session PID is not signalled", ctx do
    {job, _} = start_job(ctx, "sleep 60")
    {other, _} = start_job(%{ctx | owner: ctx.owner <> "-other"}, "sleep 60")
    eventually(fn -> Background.info(job).phase == :running end)
    eventually(fn -> Background.info(other).phase == :running end)
    real = :sys.get_state(job)
    other_pid = Background.info(other).session_pid
    :sys.replace_state(job, &%{&1 | session_pid: other_pid, session_start: "not-its-birth"})
    assert :ok = Background.cancel(job)
    assert Background.info(other).status == :running

    :sys.replace_state(
      job,
      &%{&1 | session_pid: real.session_pid, session_start: real.session_start}
    )

    send(job, :kill_retry)
    assert finished(job).reason == :cancelled
    assert :ok = Background.cancel(other)
    assert finished(other).reason == :cancelled
  end

  test "real NanoAgent restart preserves OS job, completion and dashboard attribution", ctx do
    {agent, model} = start_agent(ctx.owner)
    {command, release} = gated(ctx, "echo survived")
    {job, id} = start_job(ctx, command)
    assert Nano.Ops.process(job).kind == {:spawned_by, ctx.owner}
    info = Background.info(job)
    eventually(fn -> File.read(info.output) == {:ok, "survived\n"} end)
    Process.exit(agent, :operator_restart)

    restored =
      eventually(fn ->
        case NanoAgent.whereis(ctx.owner) do
          pid when is_pid(pid) and pid != agent -> pid
          _ -> false
        end
      end)

    assert restored != agent
    assert Process.alive?(job)
    eventually(fn -> Nano.Ops.process(job).kind == {:spawned_by, ctx.owner} end)
    assert Background.info(job).status == :running

    assert Enum.any?(
             Nano.Ops.processes(),
             &(&1.pid == job and &1.kind == {:spawned_by, ctx.owner})
           )

    Fake.push(model, calls: [idle: nil])
    assert_receive {:openrouter_request, ^model, _restart_note}, 3_000
    # Wait for the scripted idle before releasing the command; no timing sleeps.
    eventually(fn -> NanoAgent.info(ctx.owner).status == :idle end)
    Fake.push(model, calls: [idle: nil])
    File.write!(release, "")
    assert_receive {:openrouter_request, ^model, body}, 3_000
    assert inspect(body) =~ id
    assert inspect(body) =~ "background"
    refute inspect(body) =~ "survived"
    assert File.read!(info.output) == "survived\nlast\n"
    eventually(fn -> not Process.alive?(job) end)
  end

  test "completion waits for an absent owner and is delivered by name when it starts", ctx do
    {job, id} = start_job(ctx, "echo buffered")
    info = finished(job)
    assert Process.alive?(job)
    {_agent, model} = start_agent(ctx.owner)
    Fake.push(model, calls: [idle: nil])
    assert_receive {:openrouter_request, ^model, body}, 3_000
    assert inspect(body) =~ id
    assert inspect(body) =~ "background"
    refute inspect(body) =~ "buffered"
    assert info.status == 0
    eventually(fn -> not Process.alive?(job) end)
  end
end
