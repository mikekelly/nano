defmodule Nano.ContextPolicyTest.Compact do
  def before_request(snapshot) do
    case Registry.lookup(Nano.Registry, {:hook_observer, snapshot.name}) do
      [{pid, _}] -> send(pid, {:policy_boundary, snapshot})
      _ -> :ok
    end

    if snapshot.estimate > snapshot.max_context * 0.3,
      do:
        {:replace_transcript,
         [
           %{
             "role" => "user",
             "content" => "Compacted commitments: ship report; all tools answered."
           }
         ]},
      else: :keep
  end
end

defmodule Nano.ContextPolicyTest.Invalid do
  def before_request(_),
    do:
      {:replace_transcript, [%{"role" => "tool", "tool_call_id" => "orphan", "content" => "bad"}]}
end

defmodule Nano.ContextPolicyTest.Huge do
  def before_request(_),
    do: {:replace_transcript, [%{"role" => "user", "content" => String.duplicate("x", 100_000)}]}
end

defmodule Nano.ContextPolicyTest.Slow do
  def before_request(_) do
    Process.sleep(10_000)
    :keep
  end
end

defmodule Nano.ContextPolicyTest.Crash do
  def before_request(_), do: raise("failed")
end

defmodule NanoAgentContextPolicyTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    model = Fake.model()
    name = "hook#{System.unique_integer([:positive])}"
    Registry.register(Nano.Registry, {:hook_observer, name}, nil)

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
    end)

    %{model: model, name: name}
  end

  defp start(ctx, policy) do
    opts = [name: ctx.name, system_prompt: "short", max_context: 8192]
    opts = if policy, do: Keyword.put(opts, :context_policy, policy), else: opts
    Fake.listen(ctx.model)
    {:ok, pid} = NanoAgent.start(Keyword.merge(Fake.opts(ctx.model), opts))
    pid
  end

  defp await(fun, attempts \\ 200)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, n - 1)
        )
  end

  test "policy runs after every returned tool has a result, recovers context halt, never cancels tools",
       ctx do
    Fake.push(ctx.model,
      calls: [eval: "String.duplicate(\"x\", 25_000)", eval: "42"],
      usage: {9000, 100, 0}
    )

    Fake.push(ctx.model, text: "finished")
    pid = start(ctx, Nano.ContextPolicyTest.Compact)
    NanoAgent.notify(pid, :hello)
    assert_receive {:openrouter_request, model, _}, 2000
    assert model == ctx.model
    assert_receive {:policy_boundary, first}, 2000
    assert first.transcript |> List.last() |> Map.get("role") == "user"
    assert_receive {:policy_boundary, completed}, 2000
    tools = Enum.filter(completed.transcript, &(&1["role"] == "tool"))
    assert length(tools) == 2
    assert List.last(tools)["content"] == "42"
    assert_receive {:openrouter_request, ^model, request}, 2000
    assert Enum.map(request["messages"], & &1["role"]) == ["system", "user"]
    content = List.last(request["messages"])["content"]
    text = if is_list(content), do: hd(content)["text"], else: content
    assert text =~ "all tools answered"
    await(fn -> NanoAgent.info(ctx.name).status == :idle end)
    state = Nano.StateStore.get(ctx.name)
    assert state.halted == nil
    assert state.turns_used == 2
    assert state.tokens_used == 9210
    assert Enum.any?(Nano.Log.read(state.id), &(&1["type"] == "context_compacted"))
  end

  test "without opt-in original context halt behavior remains", ctx do
    Fake.push(ctx.model, calls: [eval: "String.duplicate(\"x\", 25_000)"], usage: {9000, 100, 0})
    pid = start(ctx, nil)
    NanoAgent.notify(pid, :hello)
    assert_receive {:openrouter_request, _, _}, 2000

    await(fn ->
      s = Nano.StateStore.get(ctx.name)
      s.halted == :context and s.status == :idle
    end)

    refute_receive {:openrouter_request, _, _}, 100
    assert Nano.StateStore.get(ctx.name).context_policy == nil
  end

  for policy <- [
        Nano.ContextPolicyTest.Invalid,
        Nano.ContextPolicyTest.Huge,
        Nano.ContextPolicyTest.Slow,
        Nano.ContextPolicyTest.Crash
      ] do
    test "#{inspect(policy)} fails safely and does not bypass context halt", ctx do
      Fake.push(ctx.model, calls: [eval: "42"], usage: {9000, 100, 0})
      pid = start(ctx, unquote(policy))
      NanoAgent.notify(pid, :hello)
      assert_receive {:openrouter_request, _, _}, 2000

      await(fn ->
        s = Nano.StateStore.get(ctx.name)
        s.halted == :context and s.status == :idle
      end)

      refute_receive {:openrouter_request, _, _}, 100

      assert Enum.any?(
               Nano.Log.read(Nano.StateStore.get(ctx.name).id),
               &(&1["type"] == "context_policy_error")
             )
    end
  end

  test "compaction never clears turn budget halt", ctx do
    Fake.push(ctx.model, calls: [eval: "42"], usage: {9000, 100, 0})
    pid = start(ctx, Nano.ContextPolicyTest.Compact)
    :sys.replace_state(pid, &%{&1 | max_turns: 1})
    NanoAgent.notify(pid, :hello)
    assert_receive {:openrouter_request, _, _}, 2000

    await(fn ->
      s = Nano.StateStore.get(ctx.name)
      s.halted == :budget and s.status == :idle
    end)

    refute_receive {:openrouter_request, _, _}, 100
  end

  test "module option persists across agent restart", ctx do
    Fake.push(ctx.model, text: "done")
    pid = start(ctx, Nano.ContextPolicyTest.Compact)
    NanoAgent.notify(pid, :hello)
    assert_receive {:openrouter_request, _, _}, 2000
    await(fn -> NanoAgent.info(ctx.name).status == :idle end)
    Fake.push(ctx.model, text: "restored")
    Process.exit(pid, :kill)

    await(fn ->
      new = NanoAgent.whereis(ctx.name)
      is_pid(new) and new != pid
    end)

    assert Nano.StateStore.get(ctx.name).context_policy == Nano.ContextPolicyTest.Compact
  end

  test "reject unloaded policy modules", ctx do
    assert {:error, message} =
             NanoAgent.start(
               Keyword.merge(Fake.opts(ctx.model),
                 name: ctx.name,
                 context_policy: Nano.NonexistentPolicy
               )
             )

    assert message =~ "loaded module exporting before_request/1"
  end

  test "reject non-module policy options", ctx do
    assert {:error, message} =
             NanoAgent.start(
               Keyword.merge(Fake.opts(ctx.model),
                 name: ctx.name,
                 context_policy: fn _ -> :keep end
               )
             )

    assert message =~ "module atom"
  end
end
