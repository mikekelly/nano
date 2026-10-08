defmodule NanoAgentImagesTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake
  alias Nano.ImageFixtures, as: F

  setup do
    Fake.start()
    old = Application.get_env(:nano, :images_dir)

    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "agent-images-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:nano, :images_dir, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :images_dir, old),
        else: Application.delete_env(:nano, :images_dir)

      File.rm_rf(dir)
    end)

    {:ok, ref} = Images.ingest_bytes(F.png())
    %{dir: dir, ref: ref}
  end

  defp start!(modalities, opts \\ []) do
    model = Fake.model(%{"architecture" => %{"input_modalities" => modalities}})
    name = "image-agent-#{System.unique_integer([:positive])}"
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, opts))

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
    end)

    {name, pid, model}
  end

  defp request!(model) do
    assert_receive {:openrouter_request, ^model, body}, 2000
    body
  end

  defp await_idle(name, tries \\ 200)
  defp await_idle(_name, 0), do: flunk("agent did not finish")

  defp await_idle(name, tries) do
    case NanoAgent.info(name) do
      %{status: :idle} ->
        :ok

      _ ->
        Process.sleep(10)
        await_idle(name, tries - 1)
    end
  end

  defp parts(body, type) do
    for m <- body["messages"], is_list(m["content"]), p <- m["content"], p["type"] == type, do: p
  end

  test "mailbox images reach the model as pixels but state and logs contain references", %{
    ref: ref
  } do
    {name, pid, model} = start!(["text", "image"])
    Fake.push(model, text: "red")
    NanoAgent.notify(name, Images.message("colour?", [ref]))
    body = request!(model)
    assert [%{"image_url" => %{"url" => url}}] = parts(body, "image_url")
    assert url == "data:image/png;base64," <> Base.encode64(F.png())
    await_idle(name)
    state = :sys.get_state(pid)
    assert state.input_modalities == ["text", "image"]
    assert Images.references(state.transcript) == [ref]
    refute inspect(state) =~ Base.encode64(F.png())
    assert NanoAgent.info(name).system_prompt =~ "can see attached images"
    log = Nano.Log.read(NanoAgent.info(name).id)
    assert [%{"images" => [^ref]}] = Enum.filter(log, &(&1["type"] == "event_received"))
    refute Jason.encode!(log) =~ Base.encode64(F.png())
    assert Enum.find(log, &(&1["type"] == "model_request"))["approx_input_tokens"] >= 4800
  end

  test "text-only model gets an explicit notice on every delivery, not a filename guess", %{
    ref: ref
  } do
    {name, _, model} = start!(["text"])

    for _ <- 1..2 do
      Fake.push(model, text: "cannot see")
      NanoAgent.notify(name, Images.message("describe", [ref]))
      body = request!(model)
      assert parts(body, "image_url") == []
      assert List.last(body["messages"])["content"] |> inspect() =~ "cannot see images"
      await_idle(name)
    end

    assert NanoAgent.info(name).system_prompt =~ "cannot see images"
  end

  test "eval viewer delivers image after every tool result; subsequent requests preserve bytes",
       %{dir: dir} do
    {name, pid, model} = start!(["image", "text"])
    path = Path.join(dir, "screen.png")
    File.write!(path, F.png())
    Fake.push(model, calls: [eval: "Images.view(#{inspect(path)}); :done", eval: "1 + 1"])
    Fake.push(model, text: "red square")
    send(pid, :look)
    request!(model)
    body = request!(model)
    assert [%{"image_url" => %{"url" => url}}] = parts(body, "image_url")
    last = List.last(body["messages"])
    assert last["role"] == "user"
    roles = Enum.map(body["messages"], & &1["role"])
    assert Enum.take(roles, -3) == ["tool", "tool", "user"]
    await_idle(name)
    state = :sys.get_state(pid)
    assert length(Images.references(state.transcript)) == 1

    assert [%{"images" => [_]} | _] =
             Nano.Log.read(NanoAgent.info(name).id) |> Enum.filter(&(&1["type"] == "tool_result"))

    File.write!(path, "replaced")
    Fake.push(model, text: "same")
    send(pid, :again)
    again = request!(model)
    assert [%{"image_url" => %{"url" => ^url}}] = parts(again, "image_url")
  end

  test "restart keeps recorded image modality despite catalog failure", %{ref: ref} do
    {name, pid, model} = start!(["text", "image"])
    Fake.push(model, text: "red")
    NanoAgent.notify(name, Images.message("first", [ref]))
    request!(model)
    await_idle(name)
    Fake.models(500)
    :persistent_term.erase({Nano.OpenRouter, :models})
    Fake.push(model, text: "resumed")
    Process.exit(pid, :kill)
    body = request!(model)
    assert length(parts(body, "image_url")) == 1
    await_idle(name)
    assert NanoAgent.whereis(name) != pid
    assert NanoAgent.info(name).input_modalities == ["text", "image"]
  end

  test "invalid reference is a rejection notice, not an unusable future request" do
    {name, pid, model} = start!(["text", "image"])
    Fake.push(model, text: "missing")

    NanoAgent.notify(
      name,
      Images.message("look", [%{"type" => "image_ref", "id" => "../escape"}])
    )

    body = request!(model)
    assert parts(body, "image_url") == []
    assert inspect(List.last(body["messages"])) =~ "Image not attached"
    await_idle(name)
    assert Images.references(:sys.get_state(pid).transcript) == []
  end

  test "eval references are tagged without bytes, including a value returned by ingest", %{
    dir: dir,
    ref: ref
  } do
    path = Path.join(dir, "screen.png")
    File.write!(path, F.png())

    assert {{:ok, {:images, text, [^ref]}, _}, "", []} =
             NanoAgent.run_eval("Images.view(#{inspect(path)}); :finished", [])

    assert text == ":finished"
    refute text =~ Base.encode64(F.png())

    assert {{:ok, {:images, _, [^ref]}, _}, "", []} =
             NanoAgent.run_eval("Images.ingest(#{inspect(path)})", [])

    assert {{:ok, "2", _}, "", []} = NanoAgent.run_eval("1 + 1", [])
  end
end
