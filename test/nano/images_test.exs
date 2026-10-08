defmodule Nano.ImagesTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6goIDC8zUNkCFQAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAldEVYdGRhdGU6Y3JlYXRlADIwMjYtMTAtMDhUMTI6NDc6NTErMDA6MDAp2KFtAAAAJXRFWHRkYXRlOm1vZGlmeQAyMDI2LTEwLTA4VDEyOjQ3OjUxKzAwOjAwWIUZ0QAAACh0RVh0ZGF0ZTp0aW1lc3RhbXAAMjAyNi0xMC0wOFQxMjo0Nzo1MSswMDowMA+QOA4AAAAASUVORK5CYII="

  setup do
    dir = Path.join(System.tmp_dir!(), "orion-images-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "not-an-image.txt")
    File.write!(path, Base.decode64!(@png))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: path}
  end

  defp start_agent(vision, overrides \\ []) do
    Fake.start()

    model =
      Fake.model(%{
        "architecture" => %{
          "input_modalities" => if(vision, do: ["text", "image"], else: ["text"])
        }
      })

    name = "images-#{System.unique_integer([:positive])}"
    Fake.listen(model)

    {:ok, pid} =
      NanoAgent.start([name: name, system_prompt: "Test images"] ++ Fake.opts(model, overrides))

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

    assert {:error, _} =
             Nano.Images.store(<<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 1::32, 1::32>>)

    assert {:error, _} =
             Nano.Images.store(
               Base.decode64!(
                 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6NUAAAAAASUVORK5CYII="
               )
             )

    assert {:error, _} = Nano.Images.store(String.duplicate("x", 3_750_001))

    assert {:error, _} =
             Nano.Images.store(
               <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 8001::32, 1::32, 0>>
             )

    assert {:error, _} = Nano.Images.read(%{"id" => "../../settings"})
  end

  test "shared image admission rejects oversized captions and irreducible image bundles before history mutation",
       c do
    {name, pid, model} = start_agent(true)
    assert {:ok, ref} = Nano.Images.import(c.path)
    original = Nano.StateStore.get(name).transcript

    assert {:error, caption_error} =
             NanoAgent.deliver_images(name, [ref], String.duplicate("x", 16_001))

    assert caption_error =~ "16000 bytes"
    assert Nano.StateStore.get(name).transcript == original
    refute_receive {:openrouter_request, ^model, _}, 50

    {tiny_name, _tiny_pid, tiny_model} = start_agent(true, max_context: 6000)
    assert {:error, fit_error} = NanoAgent.deliver_images(tiny_name, [ref], "small")
    assert fit_error =~ "cannot fit max_context"
    assert Nano.StateStore.get(tiny_name).transcript == []
    assert NanoAgent.info(tiny_name).halted == nil
    refute_receive {:openrouter_request, ^tiny_model, _}, 50

    # Even a direct raw cast cannot bypass the shared admission guard.
    Fake.push(model, text: "rejected")
    GenServer.cast(pid, {:images, [ref], String.duplicate("z", 16_001)})
    rejected = request(model)
    assert inspect(rejected["messages"]) =~ "Image delivery rejected"
    refute inspect(rejected) =~ String.duplicate("z", 200)
    refute inspect(rejected) =~ "data:image"
  end

  test "full decoder validates
 JPEG/static GIF and refuses animation and truncated pixels",
       c do
    jpeg = c.path <> ".jpg"
    gif = c.path <> ".gif"
    animated = c.path <> ".animated.gif"
    assert {_, 0} = System.cmd("convert", [c.path, jpeg], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("convert", [c.path, gif], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("convert", [c.path, c.path, animated], stderr_to_stdout: true)

    assert {:ok, %{"mime" => "image/jpeg", "width" => 1, "height" => 1}} =
             Nano.Images.import(jpeg)

    assert {:ok, %{"mime" => "image/gif", "width" => 1, "height" => 1}} = Nano.Images.import(gif)
    assert {:error, _} = Nano.Images.import(animated)
    png = File.read!(c.path)
    assert {:error, _} = Nano.Images.store(binary_part(png, 0, byte_size(png) - 40))
    # JPEG dimensions plus an end marker without any actual entropy/pixel data.
    assert {:error, _} =
             Nano.Images.store(<<255, 216, 255, 192, 0, 8, 8, 1::16, 1::16, 1, 255, 217>>)
  end

  test "vision agent receives
 image_url; log and saved state contain only references",
       c do
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

    request_log =
      Enum.find(Nano.Log.read(NanoAgent.info(name).id), &(&1["type"] == "model_request"))

    assert request_log["approx_input_tokens"] >= 4800
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

  test "tiny-context eval view refuses pixels in the immediate tool result while preserving value and bindings",
       c do
    {name, pid, model} = start_agent(true, max_context: 8192)
    Fake.push(model, calls: [eval: "saved = 99; Nano.Images.view(#{inspect(c.path)}); saved"])
    Fake.push(model, text: "refused without guessing")
    send(pid, :view)
    request(model)
    body = request(model)
    assert List.last(body["messages"])["role"] == "tool"
    content = inspect(List.last(body["messages"])["content"])
    assert content =~ "Image view refused"
    assert content =~ "No pixels from this eval were admitted"
    assert content =~ "99"
    refute inspect(body) =~ "data:image"
    {bindings, _} = Nano.StateStore.bindings(name)
    assert bindings[:saved] == 99
    assert NanoAgent.info(name).halted == nil

    assert Enum.any?(
             Nano.Log.read(NanoAgent.info(name).id),
             &(&1["type"] == "images_refused" and &1["source"] == "eval")
           )
  end

  test "multiple eval views preflight their accumulated bundle and retain only accepted pixels",
       c do
    {name, pid, model} = start_agent(true, max_context: 14000)

    Fake.push(model,
      calls: [
        eval: "Nano.Images.view(#{inspect(c.path)}); 10",
        eval: "Nano.Images.view(#{inspect(c.path)}); 11"
      ]
    )

    Fake.push(model, text: "one picture only")
    send(pid, :views)
    request(model)
    body = request(model)
    user = List.last(body["messages"])
    assert user["role"] == "user"
    assert Enum.count(user["content"], &(&1["type"] == "image_url")) == 1
    tools = Enum.filter(body["messages"], &(&1["role"] == "tool"))
    assert inspect(hd(tools)["content"]) =~ "10"
    assert inspect(List.last(tools)["content"]) =~ "Image view refused"
    assert inspect(List.last(tools)["content"]) =~ "11"
    assert NanoAgent.info(name).halted == nil
  end

  test "text-only eval views
 warn in the immediately following request, not a later turn",
       c do
    {_name, pid, model} = start_agent(false)
    Fake.push(model, calls: [eval: "Nano.Images.view(#{inspect(c.path)})"])
    Fake.push(model, text: "cannot see")
    send(pid, :view)
    request(model)
    body = request(model)

    assert [%{"role" => "tool"}, %{"role" => "user", "content" => content}] =
             Enum.take(body["messages"], -2)

    assert inspect(content) =~ "your model cannot see images"
    refute inspect(body) =~ "data:image"
  end

  test "eval view arrives
 as a user image after the complete tool results",
       c do
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
