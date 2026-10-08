defmodule Nano.ImagesTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6NUAAAAAASUVORK5CYII="

  setup do
    dir = Path.join(System.tmp_dir!(), "orion-images-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "not-an-image.txt")
    File.write!(path, Base.decode64!(@png))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: path}
  end

  defp start_agent(vision) do
    Fake.start()

    model =
      Fake.model(%{
        "architecture" => %{
          "input_modalities" => if(vision, do: ["text", "image"], else: ["text"])
        }
      })

    name = "images-#{System.unique_integer([:positive])}"
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name, system_prompt: "Test images"] ++ Fake.opts(model))

    on_exit(fn ->
      if p = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)
        NanoAgent.kill_tasks(p)
      end

      Nano.StateStore.delete(name)
    end)

    {name, pid, model}
  end

  defp request(model) do
    assert_receive {:openrouter_request, ^model, body}, 3_000
    body
  end

  test "sniffs bytes, snapshots once, never persists base64", c do
    assert {:ok, ref} = Nano.Images.import(c.path)
    assert ref["mime"] == "image/png"
    assert ref["width"] == 1
    File.write!(c.path, "changed")
    assert {:ok, bytes, "image/png"} = Nano.Images.read(ref)
    assert Base.encode64(bytes) == @png
    assert {:ok, ^ref} = Nano.Images.from_base64(@png)
    refute Jason.encode!(ref) =~ @png

    assert [%{"content" => [%{"type" => "text"}, image]}] =
             Nano.Images.expand([%{"content" => Nano.Images.parts("hello", [ref])}])

    assert image["image_url"]["url"] == "data:image/png;base64," <> @png
  end

  test "rejects bad type, size, dimensions and path traversal" do
    assert {:error, _} = Nano.Images.from_base64("%%")
    assert {:error, _} = Nano.Images.store("not png")
    assert {:error, _} = Nano.Images.store(String.duplicate("x", 3_750_001))

    assert {:error, _} =
             Nano.Images.store(
               <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 8001::32, 1::32, 0>>
             )

    assert {:error, _} = Nano.Images.read(%{"id" => "../../settings"})
  end

  test "vision agent receives image_url; log and saved state contain only references", c do
    {name, _pid, model} = start_agent(true)
    Fake.push(model, text: "seen")
    assert :ok = Nano.Ops.send_image(name, c.path, "What is this?")
    body = request(model)
    assert [%{"type" => "text", "text" => text}, image] = List.last(body["messages"])["content"]
    assert text =~ "What is this?"
    assert image["image_url"]["url"] == "data:image/png;base64," <> @png
    assert NanoAgent.info(name).input_modalities == ["text", "image"]
    assert NanoAgent.info(name).system_prompt =~ "You can see image attachments"
    refute inspect(Nano.StateStore.get(name)) =~ @png
    refute inspect(Nano.Log.read(NanoAgent.info(name).id)) =~ @png
    assert Enum.any?(Nano.Log.read(NanoAgent.info(name).id), &(&1["type"] == "images_received"))
  end

  test "text-only agents are told explicitly rather than getting fake visual input", c do
    {name, _pid, model} = start_agent(false)
    Fake.push(model, text: "cannot see")
    assert :ok = Nano.Ops.send_image(name, c.path)
    body = request(model)
    assert inspect(body["messages"]) =~ "your model cannot see images"
    refute inspect(body) =~ "data:image"
    assert NanoAgent.info(name).system_prompt =~ "cannot see images"
  end

  test "eval view arrives as a user image after the complete tool results", c do
    {_name, pid, model} = start_agent(true)
    Fake.push(model, calls: [eval: "Nano.Images.view(#{inspect(c.path)})", eval: "1+1"])
    Fake.push(model, text: "image seen")
    send(pid, :view)
    request(model)
    body = request(model)
    tail = Enum.take(body["messages"], -3)

    assert [
             %{"role" => "tool"},
             %{"role" => "tool"},
             %{"role" => "user", "content" => [_, %{"type" => "image_url"}]}
           ] = tail
  end
end
