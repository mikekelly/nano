defmodule Seedling.BotsE2ETest do
  use ExUnit.Case, async: false
  alias Seedling.Bots
  @moduletag :tmp_dir

  test "fake-provider agents share chat but isolate pair context and persist memory/request", %{
    tmp_dir: dir
  } do
    stopped = Supervisor.terminate_child(Nano.Supervisor, Bots) == :ok

    if pid = Process.whereis(Bots),
      do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

    keys = [
      :bots_path,
      :memory_dir,
      :bots_model,
      :bots_dispatch,
      :decision_adapter,
      :openrouter_base_url
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:nano, &1)})
    Application.put_env(:nano, :bots_path, Path.join(dir, "bots.json"))
    Application.put_env(:nano, :memory_dir, Path.join(dir, "memory"))
    Application.delete_env(:nano, :bots_dispatch)

    Application.put_env(:nano, :decision_adapter, fn body ->
      state = body["messages"] |> List.last() |> Map.fetch!("content") |> Jason.decode!()

      if state["bot_ids"],
        do: {:ok, %{"confidence" => 1.0, "data" => %{"bot_ids" => state["bot_ids"]}}},
        else: {:ok, %{"confidence" => 1.0, "data" => %{"memory_ids" => []}}}
    end)

    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    Application.put_env(:nano, :bots_model, model)
    {:ok, a} = Bots.create_bot(%{name: "A"})
    {:ok, b} = Bots.create_bot(%{name: "B"})
    {:ok, private} = Bots.create_session([a["id"]], %{title: "Private"})
    {:ok, shared} = Bots.create_session([a["id"], b["id"]], %{title: "Shared"})

    names = [
      Bots.agent_name(a["id"], private["id"]),
      Bots.agent_name(a["id"], shared["id"]),
      Bots.agent_name(b["id"], shared["id"])
    ]

    on_exit(fn ->
      for name <- names do
        if pid = NanoAgent.whereis(name),
          do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

        Nano.StateStore.delete(name)
      end

      if pid = Process.whereis(Bots),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:nano, key, value)
          :error -> Application.delete_env(:nano, key)
        end
      end

      if stopped, do: Supervisor.restart_child(Nano.Supervisor, Bots)
    end)

    code = """
    [{:agent, name}] = Registry.keys(Nano.Registry, me)
    {session, bot} = Enum.find_value(Seedling.Bots.sessions(), fn session ->
      Enum.find_value(session["bot_ids"], fn bot ->
        if Seedling.Bots.agent_name(bot, session["id"]) == name, do: {session, bot}
      end)
    end)
    Seedling.Memory.add(bot, "Prefers blue", source_session: session["id"])
    Seedling.Bots.post(session["id"], bot, "Reply from " <> name)
    """

    for _ <- 1..3, do: Nano.FakeOpenRouter.push(model, calls: [eval: code, idle: nil])
    assert {:ok, _} = Bots.say(private["id"], "private secret")
    wait(fn -> length(Bots.session(private["id"])["messages"]) == 2 end)
    assert {:ok, _} = Bots.say(shared["id"], "team plans")
    wait(fn -> length(Bots.session(shared["id"])["messages"]) == 3 end)
    wait(fn -> Enum.all?(names, &(NanoAgent.info(&1).status == :idle)) end)

    for name <- Enum.drop(names, 1) do
      refute Jason.encode!(Nano.StateStore.get(name).transcript) =~ "private secret"
    end

    assert {:ok, nodes} = Seedling.Memory.retrieve(a["id"], "blue", budget: 100)
    assert Enum.any?(nodes, &(&1["text"] == "Prefers blue"))

    assert {:ok, request} =
             Bots.request_human(b["id"], "Region?", session_id: shared["id"], reply_to: self())

    assert {:ok, _} = Bots.answer(request["id"], "EU")
    assert_receive {:bot_answer, _, "EU"}
    name = hd(names)

    assert {:ok, _} =
             Seedling.Bots.Compactor.compact(name,
               force: true,
               adapter: fn _ ->
                 {:ok,
                  %{
                    "confidence" => 1.0,
                    "data" => %{"summary" => "Private preference: blue. Responded."}
                  }}
               end
             )

    assert hd(Nano.StateStore.get(name).transcript)["content"] =~ "Private preference"
  end

  defp wait(fun, remaining \\ 200)
  defp wait(fun, 0), do: assert(fun.())

  defp wait(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait(fun, remaining - 1)
        )
  end
end
