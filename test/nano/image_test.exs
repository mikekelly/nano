defmodule Nano.ImageTest do
  use ExUnit.Case, async: true

  # A 1x1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
       )

  test "new/1 stores data once, named by its SHA-256, and the struct holds no data" do
    {:ok, image} = Nano.Image.new(@png)
    sha = Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
    path = Path.expand(Path.join(Application.fetch_env!(:nano, :image_dir), sha <> ".png"))

    assert image == %Nano.Image{sha: sha, mime: "image/png", bytes: byte_size(@png), path: path}
    assert File.read!(path) == @png
    assert inspect(image) == "#Nano.Image<#{path}, #{byte_size(@png)} bytes>"

    # The same bytes from a file are the same image.
    file =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "image-#{System.unique_integer([:positive])}.png"
      )

    File.write!(file, @png)
    on_exit(fn -> File.rm(file) end)
    assert Nano.Image.new(file) == {:ok, image}
  end

  test "each type is told by its first bytes" do
    for {data, mime, ext} <- [
          {<<0xFF, 0xD8, 0xFF, 0xE0, "jpeg">>, "image/jpeg", ".jpg"},
          {"GIF89a" <> <<1, 0, 1, 0>>, "image/gif", ".gif"},
          {"GIF87a" <> <<1, 0, 1, 0>>, "image/gif", ".gif"},
          {"RIFF" <> <<4, 0, 0, 0>> <> "WEBPVP8 ", "image/webp", ".webp"}
        ] do
      assert {:ok, %{mime: ^mime, path: path}} = Nano.Image.new(data)
      assert Path.extname(path) == ext
    end
  end

  test "anything else, too large, or unreadable is refused, saying why" do
    assert {:error, "not a PNG, JPEG, GIF or WebP image" <> _} = Nano.Image.new(<<0, 1, 2, 3>>)

    big = @png <> :binary.copy(<<0>>, 3_750_001 - byte_size(@png))
    assert Nano.Image.new(big) == {:error, "the image is 3750001 bytes; the most is 3750000"}
    assert {:ok, _} = Nano.Image.new(binary_part(big, 0, 3_750_000))

    assert Nano.Image.new("/no/such/file.png") ==
             {:error, "cannot read /no/such/file.png: no such file or directory"}

    assert {:error, "not a PNG" <> _} = Nano.Image.new(__ENV__.file)
    assert {:error, "give image data or a path" <> _} = Nano.Image.new(:nope)
  end

  test "find/1 walks any term, each image once; a struct with a malformed sha is ignored" do
    {:ok, a} = Nano.Image.new(@png)
    {:ok, b} = Nano.Image.new(<<0xFF, 0xD8, 0xFF, "other">>)

    forged = %Nano.Image{
      sha: "../../etc/passwd",
      mime: "image/png",
      bytes: 1,
      path: "/etc/passwd"
    }

    term = {:look, [%{images: [a, forged]}, {b, a}], %URI{host: b}, [1 | a]}
    assert Nano.Image.find(term) == [a, b]
    assert Nano.Image.find("no images") == []
  end

  test "parts/1 reads the data at request time, or says why it cannot" do
    {:ok, image} = Nano.Image.new(@png)
    ref = Nano.Image.ref(image)
    assert ref == %{"sha" => image.sha, "mime" => "image/png", "bytes" => image.bytes}

    assert Nano.Image.parts([ref]) == [
             {:text, inspect(image)},
             {:image, "data:image/png;base64," <> Base.encode64(@png)}
           ]

    gone = %{ref | "sha" => String.duplicate("0", 64)}

    assert [{:text, "[image not shown: " <> rest}] = Nano.Image.parts([gone])
    assert rest =~ "#{String.duplicate("0", 64)}.png cannot be read: no such file or directory]"
  end
end
