defmodule Nano.UserTest do
  use ExUnit.Case, async: true

  alias Nano.User

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp start_user(prefix \\ "u") do
    name = unique(prefix)
    pid = User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, pid) end)
    {name, pid}
  end

  # A process registered as an agent, standing in for NanoAgent, that forwards what it receives.
  defp fake_agent do
    test = self()
    name = unique("agent")

    pid =
      spawn_link(fn ->
        Registry.register(Nano.Registry, {:agent, name}, nil)
        send(test, :registered)
        forward(test)
      end)

    assert_receive :registered
    {name, pid}
  end

  defp forward(to) do
    receive do
      msg -> send(to, {:forwarded, msg})
    end

    forward(to)
  end

  test "start/1 returns the pid, registers the user, and is idempotent" do
    {name, pid} = start_user()
    assert is_pid(pid)
    assert User.start(name) == pid
    assert User.pid(name) == pid
    assert name in User.list()
    assert User.pid("nobody_#{System.unique_integer()}") == nil
  end

  test "the dashboard user is started at boot" do
    assert is_pid(User.pid("dashboard"))
  end

  test "say/3 sends %{sender_pid, message} to a pid, from inside the user process" do
    {name, user} = start_user()
    :erlang.trace(user, true, [:send])

    assert User.say(name, self(), "hello") == :ok
    assert_receive %{sender_pid: ^user, message: "hello"}
    # The send really happened in the user process.
    test = self()
    assert_receive {:trace, ^user, :send, %{message: "hello"}, ^test}
  end

  test "say/3 and send_raw/3 accept an agent name" do
    {name, _} = start_user()
    {agent, _} = fake_agent()

    assert User.say(name, agent, "hi") == :ok
    assert_receive {:forwarded, %{message: "hi", sender_pid: sender}}
    assert sender == User.pid(name)

    assert User.send_raw(name, agent, {:ping, 42}) == :ok
    assert_receive {:forwarded, {:ping, 42}}
  end

  test "send_raw/3 sends the term exactly as given" do
    {name, _} = start_user()
    term = %{note: "hi", list: [1, 2], tuple: {:a, self()}}
    assert User.send_raw(name, self(), term) == :ok
    assert_receive ^term
  end

  test "a user name is a target, and its inbox keeps messages oldest first with timestamps" do
    {alice, alice_pid} = start_user("alice")
    {bob, bob_pid} = start_user("bob")
    Phoenix.PubSub.subscribe(Nano.PubSub, "user:" <> bob)

    assert User.say(alice, bob, "one") == :ok
    assert_receive {:nano_user, %{dir: :received, term: %{message: "one"}}}
    assert User.send_raw(alice, bob, :two) == :ok
    assert_receive {:nano_user, %{dir: :received, term: :two}}
    send(bob_pid, "three")

    [first, second, third] = User.inbox(bob)
    assert first.term == %{sender_pid: alice_pid, message: "one"}
    assert second.term == :two
    assert third.term == "three"
    assert %DateTime{} = first.at
    assert DateTime.compare(first.at, third.at) in [:lt, :eq]

    assert length(User.inbox(bob, clear: true)) == 3
    assert User.inbox(bob) == []
  end

  test "GenServer calls and casts from anyone are kept in the inbox, not a crash" do
    {name, pid} = start_user()

    GenServer.cast(pid, {:reply, "hi"})
    assert {:timeout, _} = catch_exit(GenServer.call(pid, :whatever, 50))
    assert {:timeout, _} = catch_exit(GenServer.call(pid, {:send, "not a pid", {:say, "x"}}, 50))

    assert [
             %{term: {:"$gen_cast", {:reply, "hi"}}},
             %{term: {:"$gen_call", {caller, _}, :whatever}},
             %{term: {:"$gen_call", _, {:send, "not a pid", {:say, "x"}}}}
           ] = User.inbox(name)

    assert caller == self()
    assert User.pid(name) == pid
  end

  test "everything sent and received is broadcast on user:<name>" do
    {name, user} = start_user()
    Phoenix.PubSub.subscribe(Nano.PubSub, "user:" <> name)
    test = self()

    User.send_raw(name, self(), :out)
    assert_receive {:nano_user, %{dir: :sent, to: ^test, term: :out, at: %DateTime{}}}

    send(user, :in)
    assert_receive {:nano_user, %{dir: :received, to: ^user, term: :in, at: %DateTime{}}}
  end

  test "a user that does not answer is an error for the caller, not a crash" do
    {name, pid} = start_user()
    :sys.suspend(pid)
    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)

    assert User.say(name, self(), "x") == {:error, :unresponsive}
    assert User.inbox(name) == {:error, :unresponsive}
    refute_received %{message: "x"}

    :sys.resume(pid)
    assert User.inbox(name) == []
  end

  test "unknown users and targets are errors" do
    {name, _} = start_user()
    nobody = unique("nobody")

    assert User.say(nobody, self(), "x") == {:error, :unknown_user}
    assert User.send_raw(nobody, nobody, :x) == {:error, :unknown_user}
    assert User.inbox(nobody) == {:error, :unknown_user}
    assert User.say(name, nobody, "x") == {:error, :unknown_target}

    assert User.say(name, spawn(fn -> :ok end) |> tap(&wait_dead/1), "x") ==
             {:error, :unknown_target}
  end

  defp wait_dead(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
  end
end
