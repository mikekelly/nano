defmodule Vega.ImagesTest do
  use ExUnit.Case, async: true
  alias Vega.Images

  defp png(w, h),
    do: <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0>>

  test "imports byte-detected image, returns no payload, survives source mutation" do
    path =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "image-#{System.unique_integer([:positive])}.jpg"
      )

    original = png(20, 30)
    File.write!(path, original)
    assert {:ok, ref} = Images.import_file(path)
    assert ref["mime"] == "image/png"
    assert ref["width"] == 20
    refute Jason.encode!(ref) =~ Base.encode64(original)
    File.write!(path, png(10, 10))
    assert {:ok, ^original, "image/png"} = Images.fetch(ref["id"])
    assert {:ok, [^ref]} = Images.validate_refs([Map.put(ref, "width", 999)])
  end

  test "rejects bad types, oversize bytes/dimensions and traversal" do
    assert {:error, _} = Images.import_bytes("not a picture")
    assert {:error, _} = Images.import_bytes(png(2001, 1))
    assert {:error, _} = Images.import_bytes(png(1, 0))
    assert {:error, _} = Images.import_bytes(:binary.copy("x", 3_750_001))
    assert {:error, _} = Images.fetch("../../settings.json")
    assert {:error, _} = Images.validate_refs([%{"type" => "image_ref", "id" => "bogus"}])
    assert {:error, _} = Images.validate_refs(List.duplicate(%{}, 21))
  end

  test "view queues metadata; formats and token estimate don't base64 inflate" do
    path =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "view-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, png(2, 3))
    assert {:ok, ref} = Images.view(path)
    assert Images.take_views() == [ref]
    assert Images.take_views() == []
    parts = Images.content("look", [ref])

    assert [%{type: "input_text", text: "look"}, %{type: "input_image", image_url: url}] =
             Images.responses_content(parts)

    assert url =~ "data:image/png;base64,"

    assert [
             %{
               "content" => [
                 %{"type" => "text"},
                 %{"type" => "image_url", "image_url" => %{"url" => ^url}}
               ]
             }
           ] = Images.openrouter([%{"role" => "user", "content" => parts}])

    assert Images.estimated_bytes(ref) == 9600
    assert Images.vision_note(["text"]) =~ "cannot see"
    assert Images.vision_note(["text", "image"]) =~ "can see"
  end

  test "concurrent imports are atomic and corruption is refused, not silently replaced" do
    bytes = png(111, 112)

    results =
      1..20
      |> Task.async_stream(fn _ -> Images.import_bytes(bytes) end, max_concurrency: 20)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    {:ok, {:ok, ref}} = hd(results)
    path = Path.join([Application.fetch_env!(:nano, :state_dir), "images", ref["id"]])
    File.chmod!(path, 0o644)
    File.write!(path, "corrupt")
    assert {:error, _} = Images.fetch(ref["id"])
    assert {:error, "image store corruption"} = Images.import_bytes(bytes)
    File.rm!(path)
  end

  test "redacts payloads in nested provider error bodies" do
    error = %{"nested" => ["echo data:image/png;base64,aGVsbG8= end"]}
    assert Vega.Images.redact(error) == %{"nested" => ["echo [image data redacted] end"]}
  end

  test "JPEG GIF and WebP dimensions" do
    assert {:ok, "image/jpeg", 12, 8} =
             Images.dimensions(<<255, 216, 255, 192, 8::16, 8, 8::16, 12::16, 0>>)

    assert {:ok, "image/gif", 12, 8} =
             Images.dimensions(<<"GIF89a", 12::little-16, 8::little-16, 0>>)

    assert {:ok, "image/webp", 12, 8} =
             Images.dimensions(
               <<"RIFF", 20::little-32, "WEBPVP8X", 10::little-32, 0, 0::24, 11::little-24,
                 7::little-24>>
             )
  end
end
