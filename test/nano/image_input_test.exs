defmodule Nano.ImageInputTest do
  use ExUnit.Case, async: true

  test "image costs conservative tokens without storing wire data" do
    ref = %{
      image_ref: String.duplicate("a", 64),
      mime: "image/png",
      width: 1,
      height: 1,
      bytes: 42
    }

    content = Nano.ImageInput.content("see", [ref])
    assert Nano.ImageInput.estimated_bytes(content) == byte_size(Jason.encode!(content)) + 9600
    refute Jason.encode!(content) =~ "base64"
    assert Nano.ImageInput.content("text", []) == "text"
    assert Nano.ImageInput.notice([]) =~ "cannot see"
    assert Nano.ImageInput.notice(["image"]) =~ "Nano.Images.look(path, me)"
  end
end
