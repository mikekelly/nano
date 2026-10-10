defmodule NanoAgentImagesTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()

    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "agent-images-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:nano, :image_dir)
    Application.put_env(:nano, :image_dir, dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "original.dat")

    bytes =
      <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, 44, 0::little-16, 0::little-16,
        1::little-16, 1::little-16, 0, 2, 2, 68, 1, 0, 59>>

    File.write!(path, bytes)
    {:ok, ref} = Nano.Images.import_file(path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nano, :image_dir, previous),
        else: Application.delete_env(:nano, :image_dir)

      File.rm_rf!(dir)
    end)

    %{ref: ref, bytes: bytes, path: path}
  end

  defp start!(vision) do
    model =
      Fake.model(%{
        "architecture" => %{
          "input_modalities" => if(vision, do: ["text", "image"], else: ["text"])
        }
      })

    name = "image-agent-#{System.unique_integer([:positive])}"
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      if p = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)
        NanoAgent.kill_tasks(p)
      end

      Nano.StateStore.delete(name)
    end)

    {model, name, pid}
  end

  test "vision refs persist and hydrate; original changes cannot change image", c do
    {model, name, pid} = start!(true)
    Fake.push(model, text: "done")
    send(pid, %{text: "describe", images: [Map.put(c.ref, :untrusted, "discard me")]})
    assert_receive {:openrouter_request, ^model, body}, 3000
    assert [_, image] = List.last(body["messages"])["content"]
    assert image["image_url"]["url"] == "data:image/gif;base64," <> Base.encode64(c.bytes)
    File.write!(c.path, "changed")
    assert {:ok, c.bytes} == Nano.Images.read(c.ref)
    state = :sys.get_state(pid)
    assert state.input_modalities == ["text", "image"]
    refute inspect(state.transcript) =~ "base64"
    refute inspect(state.transcript) =~ "discard me"
    assert NanoAgent.info(name).system_prompt =~ "can see attached images"

    assert List.last(Nano.Log.read(state.id))["type"] in [
             "model_response",
             "turn_ended",
             "model_request",
             "event_received",
             "agent_started"
           ]

    assert Enum.any?(Nano.Log.read(state.id), &(&1["images"] != nil and &1["images"] != []))
  end

  test "text-only models get explicit notice, no image wire parts, timeline keeps refs", c do
    {model, name, pid} = start!(false)
    Fake.push(model, text: "cannot see")
    send(pid, %{text: "describe", images: [c.ref]})
    assert_receive {:openrouter_request, ^model, body}, 3000
    encoded = Jason.encode!(body)
    refute encoded =~ "image_url"
    assert encoded =~ "cannot see the 1 image attachment"
    assert NanoAgent.info(name).system_prompt =~ "cannot see images"
    state = :sys.get_state(pid)
    assert Enum.any?(Nano.Log.read(state.id), &(&1["images"] != nil and &1["images"] != []))
  end

  test "look from eval arrives as user image after all tool results", c do
    {model, _name, pid} = start!(true)
    Fake.push(model, calls: [eval: "Nano.Images.look(#{inspect(c.path)}, me)"])
    Fake.push(model, text: "seen")
    send(pid, :look)
    assert_receive {:openrouter_request, ^model, _}, 3000
    assert_receive {:openrouter_request, ^model, body}, 3000
    assert [tool, user] = Enum.take(body["messages"], -2)
    assert tool["role"] == "tool"
    assert is_binary(tool["content"])
    assert user["role"] == "user"
    assert Enum.any?(user["content"], &(&1["type"] == "image_url"))
  end

  test "capabilities survive restart without relying on provider list", c do
    {model, name, pid} = start!(true)
    Fake.push(model, text: "done")
    send(pid, %{text: "see", images: [c.ref]})
    assert_receive {:openrouter_request, ^model, _}, 3000
    wait_idle(pid, 200)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 3000
    new = wait_restart(name, pid, 200)
    state = :sys.get_state(new)
    assert state.input_modalities == ["text", "image"]
    assert state.system_prompt =~ "can see attached images"

    assert Enum.any?(state.transcript, fn message ->
             is_list(message["content"]) and
               Enum.any?(message["content"], &(&1["type"] == "image_ref"))
           end)

    refute inspect(Nano.StateStore.get(name)) =~ "base64"
  end

  defp wait_idle(_, 0), do: flunk("agent did not finish")

  defp wait_idle(pid, n) do
    if :sys.get_state(pid).status != :idle,
      do:
        (
          Process.sleep(10)
          wait_idle(pid, n - 1)
        )
  end

  defp wait_restart(_, _, 0), do: flunk("agent did not restart")

  defp wait_restart(name, old, n) do
    case NanoAgent.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        Process.sleep(10)
        wait_restart(name, old, n - 1)
    end
  end

  test "User.say structured upload reaches model as pixels", c do
    {model, name, _pid} = start!(true)
    user = "image-user-#{System.unique_integer([:positive])}"
    user_pid = Nano.User.start(user)
    assert is_pid(user_pid)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, user_pid) end)
    Fake.push(model, text: "seen")
    assert :ok = Nano.User.say(user, name, %{text: "describe", images: [c.ref]})
    assert_receive {:openrouter_request, ^model, body}, 3000
    assert Enum.any?(List.last(body["messages"])["content"], &(&1["type"] == "image_url"))
  end
end
