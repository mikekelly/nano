defmodule Nano.Tools do
  @moduledoc """
  Bounded local tools returning `{:ok, map}` or `{:error, explanation}`.
  Read and edit preserve original bytes. Read pages use one-based line offsets, listings/search zero-based result offsets.
  Defaults: 200 lines/entries, 16000 bytes (grep 100 matches, 500 chars/line).
  Every cut includes a continuation. Search includes hidden and ignored files;
  use `glob:` to narrow it. Shell saves complete output and returns its tail.
  Examples: `read("mix.exs")`, `grep("def", path: "lib", glob: "**/*.ex")`,
  `sh("mix test", cwd: "/tmp/my-worktree")`. Long jobs: `Nano.Background.start/2`.
  """
  def read(path, opts \\ []) do
    protect(fn ->
      offset = positive(opts, :offset, 1)
      limit = positive(opts, :limit, 200)
      cap = positive(opts, :max_bytes, 16000)

      File.open!(path, [:read, :binary, :raw], fn io ->
        {lines, _, next, cut} =
          Enum.reduce_while(
            Stream.repeatedly(fn -> bounded_line(io, cap) end)
            |> Stream.take_while(&(&1 != :eof))
            |> Stream.map(fn {:ok, line} -> line end),
            {[], 0, 1, false},
            fn line, {acc, size, n, _} ->
              cond do
                n < offset ->
                  {:cont, {acc, size, n + 1, false}}

                length(acc) >= limit or size + byte_size(line) > cap ->
                  {:halt, {acc, size, n, true}}

                true ->
                  {:cont, {[line | acc], size + byte_size(line), n + 1, false}}
              end
            end
          )

        cond do
          next < offset ->
            {:error, "offset #{offset} past EOF (#{next - 1} lines); use smaller offset"}

          cut and lines == [] ->
            {:error, "line #{next} exceeds max_bytes=#{cap}; increase max_bytes"}

          true ->
            {:ok,
             %{
               text: IO.iodata_to_binary(Enum.reverse(lines)),
               cut: cut,
               next_offset: if(cut, do: next),
               continuation: if(cut, do: "read with offset: #{next}", else: nil)
             }}
        end
      end)
    end)
  end

  defp bounded_line(io, cap, acc \\ "") do
    case :file.read(io, min(4096, cap + 1 - byte_size(acc))) do
      :eof ->
        if acc == "", do: :eof, else: {:ok, acc}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: "open file"

      {:ok, chunk} ->
        data = acc <> chunk

        case :binary.match(data, "\n") do
          {n, 1} ->
            :file.position(io, {:cur, -(byte_size(data) - n - 1)})

            if n + 1 > cap,
              do: raise(ArgumentError, "single line exceeds max_bytes=#{cap}; increase max_bytes")

            {:ok, binary_part(data, 0, n + 1)}

          :nomatch ->
            if byte_size(data) > cap,
              do: raise(ArgumentError, "single line exceeds max_bytes=#{cap}; increase max_bytes")

            bounded_line(io, cap, data)
        end
    end
  end

  def tail(path, opts \\ []) do
    protect(fn ->
      cap = positive(opts, :max_bytes, 16000)
      limit = positive(opts, :limit, 200)
      size = File.stat!(path).size

      text =
        File.open!(path, [:read, :binary], fn io ->
          :file.position(io, max(0, size - cap))

          case IO.binread(io, cap) do
            :eof -> ""
            text -> text
          end
        end)

      lines = String.split(text, "\n")

      {:ok,
       %{
         text: Enum.take(lines, -limit) |> Enum.join("\n"),
         bytes: size,
         cut: size > cap or length(lines) > limit,
         path: path,
         continuation: "read(path, offset: 1) for full paged output"
       }}
    end)
  end

  def write(path, content) do
    protect(fn ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      {:ok, %{path: path, bytes: IO.iodata_length(content)}}
    end)
  end

  def edit(path, old, new) do
    protect(fn ->
      text = File.read!(path)

      case if(old == "", do: [], else: :binary.matches(text, old)) do
        [] ->
          {:error, "old text not found; match exactly including whitespace and newlines"}

        [_] when old == new ->
          {:error, "replacement changes nothing"}

        [_] ->
          File.write!(path, String.replace(text, old, new, global: false))
          {:ok, %{path: path, replacements: 1, summary: "unique exact replacement applied"}}

        many ->
          {:error, "old text occurs #{length(many)} times; add context to make it unique"}
      end
    end)
  end

  def ls(path \\ ".", opts \\ []) do
    protect(fn ->
      File.ls!(path)
      |> Enum.sort()
      |> Enum.map(fn p ->
        p <> if(File.dir?(Path.join(path, p)), do: "/", else: "")
      end)
      |> page(opts)
    end)
  end

  def find(glob, opts \\ []) do
    protect(fn ->
      cwd = Path.expand(Keyword.get(opts, :cwd, "."))

      Path.wildcard(Path.join(cwd, glob), match_dot: true)
      |> Enum.map(&Path.relative_to(&1, cwd))
      |> Enum.sort()
      |> page(opts)
    end)
  end

  def grep(pattern, opts \\ []) do
    protect(fn ->
      root = Path.expand(Keyword.get(opts, :path, "."))

      if not File.exists?(root), do: raise(ArgumentError, "search path does not exist: #{root}")

      regex =
        if match?(%Regex{}, pattern),
          do: pattern,
          else:
            Regex.compile!(
              if(Keyword.get(opts, :literal, false), do: Regex.escape(pattern), else: pattern),
              if(Keyword.get(opts, :ignore_case, false), do: "i", else: "")
            )

      files =
        if File.regular?(root),
          do: [root],
          else: Path.wildcard(Path.join(root, Keyword.get(opts, :glob, "**/*")), match_dot: true)

      offset = Keyword.get(opts, :offset, 0)
      limit = positive(opts, :limit, 100)

      matches =
        files
        |> Stream.filter(&File.regular?/1)
        |> Stream.flat_map(fn file ->
          File.stream!(file, :line)
          |> Stream.with_index(1)
          |> Stream.filter(fn {line, _} -> Regex.match?(regex, line) end)
          |> Stream.map(fn {line, n} ->
            "#{Path.relative_to(file, Path.dirname(root))}:#{n}: " <>
              String.slice(String.trim_trailing(line), 0, 500)
          end)
        end)
        |> Stream.drop(offset)
        |> Enum.take(limit + 1)

      {:ok, r} = page(matches, Keyword.merge(opts, offset: 0, limit: limit))

      {:ok,
       %{
         r
         | next_offset: if(r.cut, do: offset + r.next_offset),
           continuation:
             "grep with offset: #{offset + length(r.entries)}; lines capped at 500 characters"
       }}
    end)
  end

  def sh(command, opts \\ []), do: Nano.Background.run(command, opts)

  defp page(entries, opts) do
    offset = Keyword.get(opts, :offset, 0)

    if not is_integer(offset) or offset < 0,
      do: raise(ArgumentError, "offset must be nonnegative")

    limit = positive(opts, :limit, 200)
    cap = positive(opts, :max_bytes, 16000)

    {kept, _, cut} =
      entries
      |> Enum.drop(offset)
      |> Enum.reduce_while({[], 0, false}, fn entry, {acc, bytes, _} ->
        if length(acc) >= limit or bytes + byte_size(entry) + 1 > cap,
          do: {:halt, {acc, bytes, true}},
          else: {:cont, {[entry | acc], bytes + byte_size(entry) + 1, false}}
      end)

    kept = Enum.reverse(kept)

    {:ok,
     %{
       entries: kept,
       text: Enum.join(kept, "\n"),
       cut: cut,
       next_offset: if(cut, do: offset + length(kept)),
       continuation:
         if(cut, do: "use offset: #{offset + length(kept)} or increase max_bytes", else: nil)
     }}
  end

  defp positive(opts, key, default) do
    n = Keyword.get(opts, key, default)
    if not is_integer(n) or n < 1, do: raise(ArgumentError, "#{key} must be a positive integer")
    n
  end

  @doc false
  def protect(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end
end
