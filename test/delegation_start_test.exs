defmodule DelegationStartTest.MCP do
  def fail(_, _), do: {:error, :deliberate_failure}
end

defmodule DelegationStartTest do
  use ExUnit.Case, async: false
  alias Nano.FakeChatGPT, as: Fake
  alias Nano.ChatGPT.Auth

  test "idle start enforces job model, whole window, zero budgets and MCP unavailable" do
    Fake.start()
    Fake.listen()
    :ok = Auth.logout()
    Fake.auth(:poll, [{200, :approved}])
    Fake.auth(:token, [{200, Fake.tokens()}])
    Auth.login()
    wait(fn -> Auth.status().status == :connected end)
    model = "gpt-6.1-sol"

    Fake.models([
      %{
        "slug" => model,
        "context_window" => 272_000,
        "supported_reasoning_levels" => [%{"effort" => "low"}],
        "default_reasoning_level" => "low"
      }
    ])

    :persistent_term.erase({Nano.ChatGPT, :models})
    allowed = Nano.Settings.get(:allowed_models)
    Nano.Settings.put(:allowed_models, "openai-codex/gpt-6.1-sol low")
    name = "delegate-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(name)
      Delegation.Monitor.cancel(name)
      Nano.Settings.put(:allowed_models, allowed)
      Auth.logout()
      :persistent_term.erase({Nano.ChatGPT, :models})
    end)

    assert {:error, why} =
             Delegation.subagent(name,
               parent: "parent",
               level: :engineering,
               job: "Check",
               mcp: ["missing"]
             )

    assert why =~ "MCP is not integrated"

    dir =
      Path.join(
        System.tmp_dir!(),
        "delegation-rollback-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(dir) end)
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

    copy = Path.join(dir, "child")
    work = [repo: repo, revision: "HEAD", path: copy, branch: "child"]

    assert {:error, _} =
             Delegation.subagent(name,
               parent: "parent",
               level: :engineering,
               job: "Check",
               worktree: work,
               pre: ["missing"]
             )

    refute File.exists?(copy)
    assert NanoAgent.whereis(name) == nil
    saved = Application.get_env(:nano, :delegation_mcp_initializer)
    Application.put_env(:nano, :delegation_mcp_initializer, {DelegationStartTest.MCP, :fail, []})

    try do
      assert {:error, {:mcp_initialization_failed, :deliberate_failure}} =
               Delegation.subagent(name,
                 parent: "parent",
                 level: :engineering,
                 job: "Check",
                 worktree: work,
                 mcp: ["server"]
               )

      assert NanoAgent.whereis(name) == nil
      assert Nano.StateStore.get(name) == nil
      assert Delegation.events(name) == []
      refute File.exists?(copy)
    after
      if saved,
        do: Application.put_env(:nano, :delegation_mcp_initializer, saved),
        else: Application.delete_env(:nano, :delegation_mcp_initializer)
    end

    assert {:ok, child} =
             Delegation.subagent(name, parent: "parent", level: :engineering, job: "Check")

    assert child.model == "openai-codex/gpt-6.1-sol"
    state = :sys.get_state(child.pid)
    assert state.max_context == 272_000
    assert state.max_turns == 0
    assert state.max_tokens == 0
    assert state.reasoning == "low"
    assert state.status == :idle
    assert state.turns_used == 0
    assert state.system_prompt =~ "named \"#{name}\""
    assert state.system_prompt =~ "Delegation.report(\"#{name}\", result)"
    second = name <> "-nested"

    on_exit(fn ->
      if pid = NanoAgent.whereis(second),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(second)
      Delegation.Monitor.cancel(second)
    end)

    nested =
      Task.async(fn ->
        Process.put(:"$callers", [child.pid])
        Delegation.subagent(second, level: :engineering, job: "Nested check")
      end)
      |> Task.await()

    assert {:ok, nested} = nested
    assert nested.parent == name
    assert NanoAgent.info(second).started_by == name
    refute_receive {:chatgpt_request, _, _, _}, 100
  end

  defp wait(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("timed out")

      true ->
        Process.sleep(20)
        wait(fun, attempts - 1)
    end
  end
end
