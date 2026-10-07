defmodule Nano.DelegationTest.MCPAdapter do
  def connect(name, opts) do
    send(self(), {:mcp_connect, name, opts})
    {:ok, self()}
  end

  def watch(server, child),
    do:
      (
        send(self(), {:mcp_watch, server, child})
        :ok
      )

  def status(_server), do: {:ok, %{capabilities: %{"tools" => %{}}}}
  def tools("oversized", _opts), do: {:ok, %{spilled: true, path: "unused"}}

  def tools(_server, opts) do
    if opts[:cursor] do
      {:ok, %{"tools" => [%{"name" => "second", "inputSchema" => %{}}]}}
    else
      {:ok, %{"tools" => [%{"name" => "first", "inputSchema" => %{}}], "nextCursor" => "next"}}
    end
  end

  def subscribe(server, uri, child),
    do:
      (
        send(self(), {:mcp_subscribe, server, uri, child})
        :ok
      )
end

defmodule Nano.DelegationTest.Adapter do
  def start(opts) do
    parent = self()

    pid =
      spawn(fn ->
        Registry.register(Nano.Registry, {:delegation_test, opts[:name]}, %{halted: nil})
        send(parent, {:started, self(), opts})
        loop()
      end)

    receive do
      {:started, ^pid, _} = message ->
        send(self(), message)
        {:ok, pid}
    end
  end

  defp loop do
    receive do
      {:halt, reason} ->
        [{key, _}] = Registry.keys(Nano.Registry, self()) |> Enum.map(&{&1, nil})
        Registry.update_value(Nano.Registry, key, fn _ -> %{halted: reason} end)
        loop()

      :stop ->
        :ok

      _ ->
        loop()
    end
  end

  def whereis(name) do
    case Registry.lookup(Nano.Registry, {:delegation_test, name}) do
      [{pid, _}] ->
        pid

      [] ->
        case Registry.lookup(Nano.Registry, {:delegation_test_parent, name}) do
          [{pid, _}] -> pid
          [] -> nil
        end
    end
  end

  def info(name) do
    case Registry.lookup(Nano.Registry, {:delegation_test, name}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def notify(name, message) do
    case Registry.lookup(Nano.Registry, {:delegation_test_parent, name}) do
      [{pid, _}] -> send(pid, message)
      [] -> send(whereis(name), message)
    end
  end
end

defmodule Nano.DelegationTest do
  use ExUnit.Case, async: true
  alias Nano.Delegation, as: D
  alias Nano.DelegationTest.Adapter

  setup do
    name = "delegation-test-#{System.unique_integer([:positive])}"
    parent = name <> "-parent"
    Registry.register(Nano.Registry, {:delegation_test_parent, parent}, nil)
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [
      parent: parent,
      model: "scripted/model",
      reasoning: "off",
      max_context: 32000,
      max_tokens: 100_000,
      max_turns: 10,
      storage_dir: Path.join(dir, "watches"),
      facts: "Harness facts",
      adapter: Adapter,
      poll_ms: 10
    ]

    %{name: name, parent: parent, dir: dir, opts: opts}
  end

  test "named compact reply and durable watch recovery", c do
    Registry.register(Nano.Registry, {:agent, c.parent}, nil)
    assert {:ok, h} = D.subagent(c.name, c.opts)
    assert_receive {:started, _, _}
    Process.exit(h.watcher, :kill)

    assert [{name, {:ok, watcher}}] =
             D.restore(storage_dir: h.storage_dir, adapter: Adapter, poll_ms: 10)

    assert name == c.name
    assert Process.alive?(watcher)
    assert :ok = D.reply(h, %{summary: "done", commits: ["abc"], tests: "scripted"})

    assert_receive %{delegation: :result, from: name, result: %{summary: "done"}} = event
    assert :ok = D.ack(event)

    assert name == c.name
    assert D.restore(storage_dir: h.storage_dir, adapter: Adapter) == []
    send(h.pid, :stop)
  end

  test "default MCP integration prepares named watchers subscriptions and paginated schemas", c do
    config = [config: %{"token" => "not-a-real-secret"}, subscribe: ["file:///brief"]]

    assert {:ok, h} =
             D.subagent(
               c.name,
               c.opts ++
                 [mcp: [{"files", config}], mcp_adapter: Nano.DelegationTest.MCPAdapter]
             )

    assert_receive {:mcp_connect, "files", opts}
    assert opts[:recipient] == c.name
    refute Keyword.has_key?(opts, :subscribe)
    assert_receive {:mcp_watch, "files", child}
    assert child == c.name
    assert_receive {:mcp_subscribe, "files", "file:///brief", ^child}
    assert_receive {:started, _, start_opts}
    assert start_opts[:system_prompt] =~ "second"
    refute start_opts[:system_prompt] =~ "not-a-real-secret"
    assert [%{name: "files"} = metadata] = h.mcp
    refute Map.has_key?(metadata, :tools)
    send(h.watcher, :complete)
    send(h.pid, :stop)

    assert {:error, _} =
             D.subagent(
               c.name <> "-fail",
               c.opts ++
                 [mcp: ["oversized"], mcp_adapter: Nano.DelegationTest.MCPAdapter]
             )
  end

  test "halt and death outbox survives absent parent and watcher restart", c do
    Registry.unregister(Nano.Registry, {:delegation_test_parent, c.parent})
    assert {:ok, h} = D.subagent(c.name, c.opts)
    send(h.pid, {:halt, :budget})
    Process.sleep(40)
    refute_receive %{delegation: :failure}, 20
    Process.exit(h.watcher, :kill)
    Process.sleep(10)

    assert [{_, {:ok, watcher}}] =
             D.restore(storage_dir: h.storage_dir, adapter: Adapter, poll_ms: 10)

    Registry.register(Nano.Registry, {:delegation_test_parent, c.parent}, nil)
    assert_receive %{delegation: :failure, reason: :budget} = halted, 1000
    assert :ok = D.ack(halted)
    Registry.unregister(Nano.Registry, {:delegation_test_parent, c.parent})
    Process.exit(h.pid, :kill)
    Process.sleep(40)
    Registry.register(Nano.Registry, {:delegation_test_parent, c.parent}, nil)
    assert_receive %{delegation: :failure, kind: :exit} = exited, 1000
    assert :ok = D.ack(exited)
    send(watcher, :complete)
  end

  test "terminal result persists while parent absent, retries same receipt until acknowledged",
       c do
    Registry.unregister(Nano.Registry, {:delegation_test_parent, c.parent})
    assert {:ok, h} = D.subagent(c.name, c.opts ++ [retry_ms: 20])
    assert :ok = D.reply(h, "durable result")
    send(h.pid, :stop)
    Process.sleep(40)
    refute_receive %{delegation: :failure}, 20
    Process.exit(h.watcher, :kill)
    Process.sleep(10)

    assert [{_, {:ok, watcher}}] =
             D.restore(storage_dir: h.storage_dir, adapter: Adapter, poll_ms: 10, retry_ms: 20)

    Registry.register(Nano.Registry, {:delegation_test_parent, c.parent}, nil)
    assert_receive %{delegation: :result, result: "durable result"} = event, 1000
    assert_receive %{delegation: :result, receipt: receipt}, 1000
    assert receipt == event.receipt
    refute_receive %{delegation: :failure}, 30
    assert File.exists?(Path.join(h.storage_dir, h.id <> ".term"))
    assert :ok = D.ack(event)
    assert :ok = D.ack(event)
    refute Process.alive?(watcher)
    assert D.restore(storage_dir: h.storage_dir, adapter: Adapter) == []
  end

  test "corrupt manifests are isolated during restore", c do
    assert {:ok, h} = D.subagent(c.name, c.opts)
    File.write!(Path.join(h.storage_dir, "bad.term"), "not an erlang term")
    restored = D.restore(storage_dir: h.storage_dir, adapter: Adapter)
    assert Enum.any?(restored, &match?({_, {:error, :invalid_manifest}}, &1))
    assert Enum.any?(restored, &match?({_, {:ok, _}}, &1))
    send(h.watcher, :complete)
    send(h.pid, :stop)
  end

  test "minimal documented handles normalize storage directory", c do
    minimal = %{id: "minimal-#{c.name}", name: c.name, parent: c.parent}
    assert {:ok, watcher} = D.watch(minimal, adapter: Adapter, storage_dir: c.dir, poll_ms: 10000)
    state = :sys.get_state(watcher)
    assert state.handle.storage_dir == c.dir
    send(watcher, :complete)
  end

  test "explicit settings fail before starting", c do
    assert {:error, text} = D.subagent(c.name, parent: c.parent)
    assert text =~ "model"
    assert {:error, _} = D.subagent(c.name, Keyword.put(c.opts, :max_context, 4096))
  end

  test "hashed complete pre-reading detects changes and refuses oversized reads", c do
    file = Path.join(c.dir, "brief.md")
    File.write!(file, "before")
    assert {:ok, [snapshot]} = D.pre_read([file])
    assert snapshot.content == "before"
    assert byte_size(snapshot.sha256) == 64
    assert {:ok, false} = D.changed?(snapshot)
    File.write!(file, "after")
    assert {:ok, true} = D.changed?(snapshot)
    assert {:error, _} = D.pre_read([file], 2)
    assert {:error, _} = D.pre_read([file <> "missing"])
  end

  test "one eval composes and starts idle in calling process, compact handle", c do
    assert {:ok, h} = D.subagent(c.name, c.opts ++ [prompt: "Job", role: "scout"])
    assert_receive {:started, pid, opts}
    assert pid == h.pid
    assert opts[:start_idle]
    assert opts[:model] == "scripted/model"
    assert opts[:system_prompt] =~ "Role/level: scout"
    assert opts[:system_prompt] =~ "Hand over before half"
    assert opts[:system_prompt] =~ "Nano.Delegation.reply"
    refute Map.has_key?(h, :transcript)
    send(h.watcher, :complete)
    send(pid, :stop)
  end

  test "halting and death reach named parent without spending model turns", c do
    assert {:ok, h} = D.subagent(c.name, c.opts)
    send(h.pid, {:halt, :context})
    assert_receive %{delegation: :failure, kind: :halted, reason: :context, from: name}, 1000
    assert name == c.name
    refute_receive %{delegation: :failure, kind: :halted}, 30
    Process.exit(h.pid, :kill)
    assert_receive %{delegation: :failure, kind: :exit}, 1000
    send(h.watcher, :complete)
  end

  test "MCP callback runs before child starts and only public handles enter prompt", c do
    owner = self()

    setup = fn name, servers ->
      send(owner, {:mcp_ready, name, servers})
      {:ok, ["session"]}
    end

    assert {:ok, h} = D.subagent(c.name, c.opts ++ [mcp: ["server"], mcp_setup: setup])
    assert_receive {:mcp_ready, _, ["server"]}
    assert_receive {:started, _, opts}
    assert opts[:system_prompt] =~ "session"
    send(h.watcher, :complete)
    send(h.pid, :stop)
    assert {:error, _} = D.subagent(c.name <> "-2", c.opts ++ [mcp: ["server"]])
  end

  test "worktree uses requested revision, unique branch, isolated shell environment", c do
    repo = Path.join(c.dir, "repo")
    File.mkdir_p!(repo)
    cmd = fn args -> System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) end
    {_, 0} = cmd.(["init"])
    File.write!(Path.join(repo, "file"), "original")
    {_, 0} = cmd.(["add", "file"])

    {_, 0} =
      cmd.([
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-m",
        "initial"
      ])

    {sha, 0} = cmd.(["rev-parse", "HEAD"])
    path = Path.join(c.dir, "worktree")
    assert {:ok, w} = D.workspace(c.name, repo: repo, path: path, revision: String.trim(sha))
    assert w.revision == String.trim(sha)
    assert {"MIX_ENV", "test"} in w.env
    assert {"MIX_BUILD_ROOT", Path.join(path, "_build-isolated")} in w.env
    File.write!(Path.join(path, "file"), "child")
    assert File.read!(Path.join(repo, "file")) == "original"
    assert {:error, _} = D.workspace(c.name, repo: repo, path: path)
    {_, 0} = cmd.(["worktree", "remove", "--force", path])
  end
end
