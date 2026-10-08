defmodule Seedling.ImageFixture do
  @moduledoc false
  def png(w \\ 1, h \\ 1) do
    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(:binary.copy(<<0>> <> :binary.copy(<<255, 0, 0>>, w), h))) <>
      chunk("IEND", "")
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end
