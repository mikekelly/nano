defmodule Vega.DelegationTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    model = Fake.model()
    name = "delegation-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      if pid = :global.whereis_name({Vega.Delegation.Watcher, name}),
        do: if(is_pid(pid), do: GenServer.stop(pid))

      Nano.StateStore.delete(name)
    end)

    %{model: model, name: name}
  end

  test "real child evaluates report protocol and parent receives concise result", c do
    Fake.push(c.model,
      calls: [
        eval:
          "Vega.Delegation.report(#{inspect(c.name)}, %{summary: \"done\", tests: \"scripted real harness\"})"
      ]
    )

    opts =
      Fake.opts(c.model, max_turns: 2) ++
        [parent: self(), job: "report done", message: %{message: "go"}]

    assert {:ok, h} = Vega.Delegation.subagent(c.name, opts)
    assert h.name == c.name
    assert_receive %{delegation: :result, child: name, result: %{summary: "done"}}, 3000
    assert name == c.name
  end

  test "budget halt and death are reported; named address survives restart", c do
    Fake.push(c.model, text: "one turn")

    assert {:ok, _} =
             Vega.Delegation.subagent(
               c.name,
               Fake.opts(c.model, max_turns: 1) ++ [parent: self(), message: "go", poll_ms: 10]
             )

    assert_receive %{delegation: :halted, result: %{reason: :budget}}, 3000
    old = NanoAgent.whereis(c.name)
    Process.exit(old, :kill)
    assert_receive %{delegation: :down, result: %{reason: :killed}}, 3000
    Process.sleep(100)
    assert NanoAgent.whereis(c.name) != old
    assert :ok == Vega.Delegation.tell(c.name, "checkpoint")
  end

  test "hashed pre-reading and changed detection", _ do
    p =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "pre-#{System.unique_integer([:positive])}"
      )

    File.write!(p, "hello")
    assert {:ok, [pre]} = Vega.Delegation.preread([p])
    assert {:ok, false} = Vega.Delegation.changed?(pre)
    File.write!(p, "changed")
    assert {:ok, true} = Vega.Delegation.changed?(pre)
    assert {:error, {:pre_read_too_large, _, 1}} = Vega.Delegation.preread([p], 1)
    assert {:ok, prompt} = Vega.Delegation.compose("child", "parent", [job: "JOB"], [pre])
    assert prompt =~ pre.sha256
    assert prompt =~ "JOB"
  end

  test "isolated git worktree and MCP startup hook", c do
    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "repo-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", dir])
    File.write!(Path.join(dir, "a"), "committed")
    {_, 0} = System.cmd("git", ["-C", dir, "add", "."])

    {_, 0} =
      System.cmd("git", [
        "-C",
        dir,
        "-c",
        "user.name=Test",
        "-c",
        "user.email=t@t",
        "commit",
        "-m",
        "initial"
      ])

    path = dir <> "-child"
    on_exit(fn -> File.rm_rf(path) end)

    opts =
      Fake.opts(c.model) ++
        [parent: self(), worktree: [repo: dir, path: path], mcp_hook: {__MODULE__, :mcp, []}]

    assert {:ok, h} = Vega.Delegation.subagent(c.name, opts)
    assert h.workspace.path == path
    assert File.read!(Path.join(path, "a")) == "committed"
    File.write!(Path.join(path, "a"), "child")
    assert File.read!(Path.join(dir, "a")) == "committed"
    assert NanoAgent.info(c.name).system_prompt =~ "mcp-ready"
  end

  test "watcher supervision and durable reattachment", c do
    dir = Path.join(Application.fetch_env!(:nano, :test_dir), "monitors")
    # Named parent persists; use an existing idle child as reply address.
    assert {:ok, _} =
             Vega.Delegation.subagent(
               c.name,
               Fake.opts(c.model) ++ [parent: c.name, state_dir: dir]
             )

    path = Path.join(dir, c.name <> ".json")
    assert File.exists?(path)
    watcher = :global.whereis_name({Vega.Delegation.Watcher, c.name})
    Process.exit(watcher, :kill)
    Process.sleep(50)
    new = :global.whereis_name({Vega.Delegation.Watcher, c.name})
    assert is_pid(new) and new != watcher
    assert Process.info(new, :group_leader) == {:group_leader, Process.whereis(:user)}
    # Simulate full watcher service loss, not just one watcher restart.
    DynamicSupervisor.terminate_child(Vega.Delegation.Supervisor, new)
    assert [{:ok, restored}] = Vega.Delegation.restore(dir)
    assert is_pid(restored)

    assert {:error, :result_too_large_use_artifact_path} =
             Vega.Delegation.report(c.name, %{summary: String.duplicate("x", 20_000)})

    assert :ok = Vega.Delegation.report(c.name, %{summary: "done"})
    assert [{:ok, :completed}] = Vega.Delegation.restore(dir)
    assert :ok = Vega.Delegation.unwatch(c.name)
    assert :undefined == :global.whereis_name({Vega.Delegation.Watcher, c.name})
    refute File.exists?(path)
  end

  test "starts in parent's eval so harness preserves started_by", c do
    parent = c.name <> "-parent"
    child_opts = Fake.opts(c.model) ++ [job: "wait"]
    code = "Vega.Delegation.subagent(#{inspect(c.name)}, #{inspect(child_opts)})"
    Fake.push(c.model, calls: [eval: code])
    assert {:ok, pp} = NanoAgent.start([name: parent] ++ Fake.opts(c.model, start_idle: false))

    on_exit(fn ->
      if p = NanoAgent.whereis(parent),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      NanoAgent.kill_tasks(pp)
      Nano.StateStore.delete(parent)
    end)

    wait_for_child(c.name, 100)
    assert NanoAgent.info(c.name).started_by == parent
    assert NanoAgent.info(c.name).system_prompt =~ "parent: #{inspect(parent)}"
  end

  defp wait_for_child(_, 0), do: flunk("child not started")

  defp wait_for_child(name, n) do
    if NanoAgent.whereis(name),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for_child(name, n - 1)
        )
  end

  test "invalid configuration and unreadable pre-read are errors before start", c do
    assert {:error, :explicit_model_and_limits_required} =
             Vega.Delegation.subagent(c.name, parent: self())

    assert {:error, {:pre_read, _, _}} =
             Vega.Delegation.subagent(
               c.name,
               Fake.opts(c.model) ++ [parent: self(), pre: ["/nonexistent-vega-input"]]
             )

    assert {:error, :poll_ms_must_be_at_least_10} =
             Vega.Delegation.subagent(c.name, Fake.opts(c.model) ++ [parent: self(), poll_ms: 0])

    refute NanoAgent.whereis(c.name)
  end

  test "absent named parent queues result on disk and receives it when available", c do
    parent = c.name <> "-late"
    dir = Path.join(Application.fetch_env!(:nano, :test_dir), "late-monitors")

    assert {:ok, _} =
             Vega.Delegation.subagent(
               c.name,
               Fake.opts(c.model) ++ [parent: parent, poll_ms: 10, state_dir: dir]
             )

    assert :ok = Vega.Delegation.report(c.name, %{summary: "retained"})
    watcher = :global.whereis_name({Vega.Delegation.Watcher, c.name})
    DynamicSupervisor.terminate_child(Vega.Delegation.Supervisor, watcher)
    assert [{:ok, _}] = Vega.Delegation.restore(dir)

    File.read!(Path.join(dir, c.name <> ".json"))
    |> Jason.decode!()
    |> Map.fetch!("pending")
    |> length()
    |> then(&assert(&1 == 1))

    Fake.listen(c.model)
    assert :yes = Nano.Names.register_name({:agent, parent}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, parent}) end)

    assert_receive {:"$gen_cast",
                    {:notify, %{delegation: :result, result: %{summary: "retained"}}}},
                   1000

    # Disk queue is cleared after delivery and terminal jobs don't keep polling.
    Process.sleep(30)
    assert Jason.decode!(File.read!(Path.join(dir, c.name <> ".json")))["pending"] == []
  end

  test "watcher startup failure rolls back the already-created child", c do
    path =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "not-a-directory-#{System.unique_integer([:positive])}"
      )

    File.write!(path, "file")

    assert {:error, _} =
             Vega.Delegation.subagent(
               c.name,
               Fake.opts(c.model) ++ [parent: c.name <> "-parent", state_dir: path]
             )

    refute NanoAgent.whereis(c.name)
    refute NanoAgent.info(c.name)
  end

  defmodule MCPAdapter do
    def connect("fail-connect", _), do: {:error, :connection_failed}

    def connect(server, config) do
      send(Process.get(:mcp_listener), {:mcp_connected, server, config})
      {:ok, %{secret: "do-not-inject-this-info"}}
    end

    def watch("fail-watch", _), do: {:error, :watch_failed}
    def watch("crash-watch", _), do: raise("watch fixture exception")

    def watch(server, child) do
      send(Process.get(:mcp_listener), {:mcp_watching, server, child, NanoAgent.whereis(child)})
      :ok
    end

    def unwatch(server, child) do
      send(Process.get(:mcp_listener), {:mcp_unwatching, server, child})
      :ok
    end
  end

  test "MCP servers connect and bind to child before its first turn, no config leaks", c do
    Process.put(:mcp_listener, self())
    config = %{"command" => "fixture", "headers" => %{"Authorization" => "secret-key"}}

    opts =
      Fake.opts(c.model) ++
        [parent: self(), mcp_servers: [{"tools", config}, "configured"], mcp_module: MCPAdapter]

    assert {:ok, _} = Vega.Delegation.subagent(c.name, opts)
    assert_receive {:mcp_connected, "tools", ^config}
    assert_receive {:mcp_connected, "configured", nil}
    assert_receive {:mcp_watching, "tools", name, pid}
    assert name == c.name and is_pid(pid)
    prompt = NanoAgent.info(c.name).system_prompt
    assert prompt =~ "Vega.MCP.call_tool"
    assert prompt =~ "configured"
    refute prompt =~ "secret-key"
    refute prompt =~ "do-not-inject-this-info"
  end

  test "MCP connect or post-launch binding failure refuses/rolls back child", c do
    Process.put(:mcp_listener, self())
    base = Fake.opts(c.model) ++ [parent: self(), mcp_module: MCPAdapter]

    assert {:error, {:mcp_start, "fail-connect", :connection_failed}} =
             Vega.Delegation.subagent(c.name, base ++ [mcp_servers: ["fail-connect"]])

    assert {:error, {:mcp_watch, "fail-watch", :watch_failed}} =
             Vega.Delegation.subagent(c.name, base ++ [mcp_servers: ["fail-watch"]])

    refute NanoAgent.whereis(c.name)
    assert :undefined == :global.whereis_name({Vega.Delegation.Watcher, c.name})

    assert {:error, {:mcp_watch, "crash-watch", _}} =
             Vega.Delegation.subagent(c.name, base ++ [mcp_servers: ["crash-watch"]])

    refute NanoAgent.whereis(c.name)
  end

  def mcp, do: {:ok, "mcp-ready"}
end
