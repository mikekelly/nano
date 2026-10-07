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

  def mcp, do: {:ok, "mcp-ready"}
end
