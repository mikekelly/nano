defmodule Nano.ImageFixture do
  @moduledoc false
  def png(w, h) when w > 0 and h > 0 do
    row = <<0>> <> :binary.copy(<<23, 67, 91>>, w)
    pixels = :binary.copy(row, h)

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(pixels)) <> chunk("IEND", <<>>)
  end

  def png(w, h),
    do: <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0>>

  defp chunk(kind, data),
    do: <<byte_size(data)::32, kind::binary, data::binary, :erlang.crc32(kind <> data)::32>>
end
