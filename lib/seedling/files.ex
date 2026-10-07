defmodule Seedling.Files do
  @moduledoc "Bounded file utilities. Paths are unrestricted; errors are returned, not raised."
  def read(path, opts \\ []) do
    protect(fn ->
      offset = Keyword.get(opts, :offset, 0)
      limit = Keyword.get(opts, :lines, 100) |> min(500) |> max(1)
      cap = Keyword.get(opts, :bytes, 12000) |> min(24000) |> max(1)
      lines = File.stream!(path) |> Stream.drop(offset) |> Enum.take(limit + 1)
      text = lines |> Enum.take(limit) |> Enum.join()
      clipped = byte_size(text) > cap
      text = binary_part(text, 0, min(byte_size(text), cap))

      {:ok,
       %{
         text: text,
         offset: offset,
         next_offset: offset + min(length(lines), limit),
         more: length(lines) > limit,
         clipped: clipped
       }}
    end)
  end

  def write(path, content), do: File.write(path, content)

  def edit(path, old, new) when old != "" do
    with {:ok, content} <- File.read(path) do
      case length(:binary.matches(content, old)) do
        1 -> File.write(path, String.replace(content, old, new, global: false))
        n -> {:error, {:expected_one_match, n}}
      end
    end
  end

  def ls(path \\ ".", opts \\ []) do
    with {:ok, entries} <- File.ls(path), do: bounded(Enum.sort(entries), opts)
  end

  def find(glob, opts \\ []), do: protect(fn -> bounded(Path.wildcard(glob), opts) end)

  def grep(pattern, opts \\ []) do
    protect(fn ->
      max_matches = Keyword.get(opts, :limit, 100) |> min(500) |> max(1)

      matches =
        Path.wildcard(Keyword.get(opts, :glob, "/app/lib/**/*.ex"))
        |> Stream.filter(&File.regular?/1)
        |> Stream.flat_map(fn path ->
          File.stream!(path)
          |> Stream.with_index(1)
          |> Stream.filter(fn {line, _} -> String.contains?(line, pattern) end)
          |> Stream.map(fn {line, n} ->
            %{path: path, line: n, text: String.slice(line, 0, 500)}
          end)
        end)
        |> Enum.take(max_matches + 1)

      {:ok, %{matches: Enum.take(matches, max_matches), more: length(matches) > max_matches}}
    end)
  end

  def tail(path, opts \\ []) do
    protect(fn ->
      cap = Keyword.get(opts, :bytes, 12000) |> min(24000) |> max(1)
      {:ok, stat} = File.stat(path)

      File.open!(path, [:read, :binary], fn io ->
        :file.position(io, max(0, stat.size - cap))

        text =
          case IO.binread(io, cap) do
            :eof -> ""
            text -> text
          end

        {:ok,
         %{
           text:
             text
             |> String.split("\n")
             |> Enum.take(-(Keyword.get(opts, :lines, 100) |> min(500) |> max(1)))
             |> Enum.join("\n"),
           bytes: stat.size,
           path: path,
           clipped: stat.size > cap
         }}
      end)
    end)
  end

  defp bounded(entries, opts) do
    cap = Keyword.get(opts, :limit, 200) |> min(500) |> max(1)
    {:ok, %{entries: Enum.take(entries, cap), more: length(entries) > cap}}
  end

  defp protect(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  end
end
