defmodule DelegationTest.Adapter do
  def whereis({:parent, pid}), do: if(Process.alive?(pid), do: pid)
  def whereis({:parent_state, state}), do: Agent.get(state, & &1)
  def whereis({:child, state}), do: Agent.get(state, & &1.pid)
  def whereis(_), do: nil
  def info({:child, state}), do: Agent.get(state, &%{halted: &1.halted})
  def notify({:parent_state, state}, event), do: send(Agent.get(state, & &1), event)
  def notify({:parent, pid}, event), do: send(pid, event)
end

defmodule DelegationTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "delegation-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "whole seed, partial comments removed, job and reporting, hashed reading", %{dir: dir} do
    path = Path.join(dir, "input")
    File.write!(path, "hello\n")

    {:ok, composed} =
      Delegation.Prompt.compose(
        name: "child",
        parent: "parent",
        level: :engineering,
        job: "Check input",
        pre: [path]
      )

    seed = File.read!(Path.expand("../prompts/seed.txt", __DIR__))
    assert String.starts_with?(composed.prompt, seed)

    assert composed.provenance.seed.sha256 ==
             Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

    assert length(composed.provenance.partials) == 2

    assert composed.provenance.composed_sha256 ==
             Base.encode16(:crypto.hash(:sha256, composed.prompt), case: :lower)

    assert composed.prompt =~ "Delegation.report(\"child\", result)"
    assert composed.prompt =~ "preserving this composition rule"
    refute composed.prompt =~ "{{!"
    assert [%{bytes: 6, sha256: hash}] = composed.pre
    assert hash == Base.encode16(:crypto.hash(:sha256, "hello\n"), case: :lower)

    assert {:error, _} =
             Delegation.Prompt.compose(name: "x", parent: "p", job: "x", flavours: ["../seed"])
  end

  test "pre-reading limits, errors and changed hashes", %{dir: dir} do
    path = Path.join(dir, "input")
    File.write!(path, String.duplicate("x", 32_769))
    assert {:error, _} = Delegation.Prompt.preread([path], dir)
    assert {:error, _} = Delegation.Prompt.preread([dir], dir)
    assert {:error, _} = Delegation.Prompt.preread(["missing"], dir)
    File.write!(path, <<255>>)
    assert {:error, _} = Delegation.Prompt.preread([path], dir)
    File.write!(path, String.duplicate("x", 32_768))
    assert {:error, _} = Delegation.Prompt.preread([path, path, path, path], dir)
    {:ok, [first]} = Delegation.Prompt.preread([path], dir)
    File.write!(path, "changed")
    {:ok, [second]} = Delegation.Prompt.preread([path], dir)
    refute first.sha256 == second.sha256
  end

  test "model pairs and revision isolation", %{dir: dir} do
    assert {:ok, "openai-codex/gpt-6.1-sol"} = Delegation.model(:engineering)
    assert {:ok, "openai-codex/gpt-6-astra"} = Delegation.model(:exec)
    assert {:error, _} = Delegation.model(:other)
    assert {:error, _} = Delegation.worktree(path: dir, branch: "x")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-b", "main", repo])

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.com",
          "commit",
          "--allow-empty",
          "-m",
          "base"
        ],
        cd: repo
      )

    path = Path.join(dir, "child")

    assert {:ok, w} =
             Delegation.worktree(repo: repo, path: path, branch: "child", revision: "HEAD")

    assert w.path == path
    assert byte_size(w.revision) == 40

    assert {:error, _} =
             Delegation.worktree(repo: repo, path: path, branch: "other", revision: "HEAD")
  end

  test "durable results, halts, death and reattachment without model calls", %{dir: dir} do
    {:ok, state} =
      Agent.start_link(fn -> %{pid: spawn(fn -> Process.sleep(:infinity) end), halted: nil} end)

    child = {:child, state}
    parent = {:parent, self()}
    name = {:global, {:delegation_test, make_ref()}}

    {:ok, monitor} =
      Delegation.Monitor.start_link(dir: dir, name: name, adapter: DelegationTest.Adapter)

    on_exit(fn -> if Process.alive?(monitor), do: GenServer.stop(monitor) end)
    assert :ok = Delegation.Monitor.reserve(child, parent, monitor)
    assert {:error, _} = Delegation.Monitor.reserve(child, parent, monitor)
    assert :ok = Delegation.Monitor.activate(child, monitor)
    assert :ok = Delegation.Monitor.emit(child, :result, %{result: "done"}, monitor)
    assert_receive %{delegation: :result, result: "done", event_id: id}, 1500

    assert {:error, _} =
             Delegation.Monitor.emit(
               child,
               :result,
               %{result: String.duplicate("x", 20_000)},
               monitor
             )

    assert :ok = Delegation.Monitor.ack(id, monitor)
    Agent.update(state, &%{&1 | halted: :budget})
    send(monitor, :tick)
    assert_receive %{delegation: :halted, reason: :budget}, 1500
    pid = Agent.get(state, & &1.pid)
    Process.exit(pid, :kill)
    Agent.update(state, &%{&1 | pid: nil})
    assert_receive %{delegation: :death}, 1500
    new = spawn(fn -> Process.sleep(:infinity) end)
    Agent.update(state, &%{&1 | pid: new, halted: nil})
    send(monitor, :tick)
    assert_receive %{delegation: :restarted}, 1500
    Process.exit(new, :kill)
    before = Delegation.Monitor.events(child, monitor)
    GenServer.stop(monitor)

    {:ok, restored} =
      Delegation.Monitor.start_link(dir: dir, name: name, adapter: DelegationTest.Adapter)

    assert Enum.all?(before, &(&1 in Delegation.Monitor.events(child, restored)))
    GenServer.stop(restored)
  end

  test "parent restart receives durable undelivered result by stable address", %{dir: dir} do
    {:ok, parent_state} = Agent.start_link(fn -> nil end)
    parent = {:parent_state, parent_state}
    name = {:global, {:delegation_outbox, make_ref()}}

    {:ok, m} =
      Delegation.Monitor.start_link(dir: dir, name: name, adapter: DelegationTest.Adapter)

    assert :ok = Delegation.Monitor.reserve("child", parent, m)
    assert :ok = Delegation.Monitor.emit("child", :result, %{result: "saved"}, m)
    refute_receive %{delegation: :result}, 30
    GenServer.stop(m)

    {:ok, restored} =
      Delegation.Monitor.start_link(dir: dir, name: name, adapter: DelegationTest.Adapter)

    pid = self()
    Agent.update(parent_state, fn _ -> pid end)
    send(restored, :deliver)
    assert_receive %{delegation: :result, from: "child", result: "saved", event_id: id}, 1500
    assert :ok = Delegation.Monitor.ack(id, restored)
    assert [] = Delegation.Monitor.events("child", restored)
    GenServer.stop(restored)
  end

  test "retries are sparse, retain IDs, and immediately follow parent pid changes", %{dir: dir} do
    test_pid = self()

    old_parent =
      spawn(fn ->
        receive do
          event ->
            send(test_pid, {:first_delivery, event})
            Process.sleep(:infinity)
        end
      end)

    {:ok, parent_state} = Agent.start_link(fn -> old_parent end)
    name = {:global, {:delegation_retry, make_ref()}}

    {:ok, m} =
      Delegation.Monitor.start_link(dir: dir, name: name, adapter: DelegationTest.Adapter)

    assert :sys.get_state(m).retry_interval_ms == 60_000
    assert :ok = Delegation.Monitor.reserve("child", {:parent_state, parent_state}, m)
    assert :ok = Delegation.Monitor.emit("child", :result, %{result: "once"}, m)
    assert_receive {:first_delivery, %{event_id: id}}, 1000
    send(m, :deliver)
    refute_receive {:first_delivery, _}, 30
    Process.exit(old_parent, :kill)
    Agent.update(parent_state, fn _ -> test_pid end)
    send(m, :deliver)
    assert_receive %{event_id: ^id, result: "once"}, 1000
    send(m, :deliver)
    refute_receive %{event_id: ^id}, 30

    :sys.replace_state(m, fn s ->
      %{s | last_delivery: %{id => {test_pid, System.monotonic_time(:millisecond) - 60_001}}}
    end)

    send(m, :deliver)
    assert_receive %{event_id: ^id}, 1000

    :sys.replace_state(m, fn s ->
      s
      |> Map.delete(:retry_interval_ms)
      |> Map.put(:last_delivery, %{id => System.monotonic_time(:millisecond)})
    end)

    send(m, :deliver)
    assert_receive %{event_id: ^id}, 1000
    assert :ok = Delegation.Monitor.ack(id, m)
    send(m, :deliver)
    refute_receive %{event_id: ^id}, 30
    GenServer.stop(m)
  end

  test "quiet polls leave durable file untouched", %{dir: dir} do
    name = {:global, {:delegation_quiet, make_ref()}}

    {:ok, m} =
      Delegation.Monitor.start_link(
        dir: dir,
        name: name,
        adapter: DelegationTest.Adapter,
        retry_interval_ms: 120_000
      )

    assert :ok = Delegation.Monitor.reserve("child", {:parent, self()}, m)
    path = Path.join(dir, "registry.term")
    ancient = {{2000, 1, 1}, {0, 0, 0}}
    :ok = File.touch(path, ancient)
    send(m, :tick)
    :sys.get_state(m)
    assert File.stat!(path).mtime == ancient
    assert :sys.get_state(m).retry_interval_ms == 120_000
    GenServer.stop(m)
  end
end
