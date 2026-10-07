defmodule Seedling.BotsTest do
  use ExUnit.Case, async: false
  alias Seedling.Bots
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    root_stopped = Supervisor.terminate_child(Nano.Supervisor, Bots) == :ok

    if pid = Process.whereis(Bots),
      do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

    old = Application.get_env(:nano, :bots_path)
    Application.put_env(:nano, :bots_path, Path.join(dir, "bots.json"))
    parent = self()

    Application.put_env(:nano, :bots_dispatch, fn bot, session, text ->
      send(parent, {:dispatched, bot, session, text})
    end)

    on_exit(fn ->
      if pid = Process.whereis(Bots),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      if old,
        do: Application.put_env(:nano, :bots_path, old),
        else: Application.delete_env(:nano, :bots_path)

      Application.delete_env(:nano, :bots_dispatch)
      if root_stopped, do: Supervisor.restart_child(Nano.Supervisor, Bots)
    end)

    :ok
  end

  test "identities and separate shared sessions survive service restart" do
    assert {:ok, a} = Bots.create_bot(%{name: "A", description: "Calm"})
    assert {:ok, b} = Bots.create_bot(%{"name" => "B"})
    assert {:ok, one} = Bots.create_session([a["id"]])
    assert {:ok, shared} = Bots.create_session([a["id"], b["id"]], %{title: "Team"})
    assert {:ok, _} = Bots.say(shared["id"], "Hello team")
    assert_receive {:dispatched, ^a, _, "Hello team"}
    assert_receive {:dispatched, ^b, _, "Hello team"}
    assert {:ok, _} = Bots.post(shared["id"], a["id"], "Hi <script>")
    assert Bots.session(one["id"])["messages"] == []
    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, Process.whereis(Bots))
    assert length(Bots.bots()) == 2

    assert Enum.map(Bots.session(shared["id"])["messages"], & &1["text"]) == [
             "Hello team",
             "Hi <script>"
           ]
  end

  test "human request is durable answerable once and routed back" do
    {:ok, bot} = Bots.create_bot(%{name: "Muse"})
    {:ok, session} = Bots.create_session([bot["id"]])

    {:ok, request} =
      Bots.request_human(bot["id"], "Which option?", reply_to: self(), session_id: session["id"])

    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, Process.whereis(Bots))
    assert {:ok, answer} = Bots.answer(request["id"], "Blue")
    assert answer["status"] == "answered"
    assert_receive {:bot_answer, id, "Blue"}
    assert id == request["id"]
    assert {:error, :already_answered} = Bots.answer(id, "Red")
  end

  test "validation and settings do not expose eval or cross bot post" do
    assert {:error, :invalid_name} = Bots.create_bot(%{})
    assert {:error, :invalid_bots} = Bots.create_session(["missing"])
    {:ok, bot} = Bots.create_bot(%{name: "One"})
    {:ok, session} = Bots.create_session([bot["id"]])
    assert {:error, :invalid_message} = Bots.post(session["id"], "intruder", "bad")
    assert {:error, :invalid_text} = Bots.say(session["id"], "")

    assert {:ok, %{"notifications" => true, "quiet" => false}} =
             Bots.settings(session["id"], %{notifications: true})
  end
end
