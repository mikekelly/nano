defmodule Nano.Tools do
  @moduledoc """
  Bounded filesystem and shell helpers. All return `{:ok, map}` or `{:error, reason}`.
  `read(path, offset: 1, limit: 200, max_bytes: 16000)` pages lines; `tail/2` keeps the end.
  `write/2`, `edit(path, old, new)` (unique exact replacement), `ls/2`, `find/2`,
  `grep(pattern, path: ".")`, and `sh(command, cwd: ".", timeout: 30000)`.
  Shell output is saved in full; use `tail(result.path)` to inspect it.
  """
  defguardp positive(n) when is_integer(n) and n > 0

  def read(path, opts \\ []) do
    safe(fn ->
      offset = Keyword.get(opts, :offset, 1)
      limit = Keyword.get(opts, :limit, 200)
      cap = Keyword.get(opts, :max_bytes, 16_000)

      unless positive(offset) and positive(limit) and positive(cap),
        do: throw({:error, "offset, limit and max_bytes must be positive integers"})

      with {:ok, stat} <- File.stat(path) do
        unless stat.type == :regular, do: throw({:error, "read requires a regular file"})
        {:ok, file} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

        {kept, total, bytes, stopped, _, _} =
          try do
            read_chunks(file, {[], 0, 0, false, "", 0}, offset, limit, cap)
          after
            :file.close(file)
          end

        cond do
          offset > max(total, 1) ->
            {:error, "offset past EOF (#{total} lines)"}

          kept == [] and stopped ->
            {:error, "line #{offset} exceeds max_bytes=#{cap}; increase max_bytes"}

          true ->
            more = offset - 1 + length(kept) < total

            {:ok,
             %{
               text: kept |> Enum.reverse() |> Enum.join("\n"),
               bytes: bytes,
               total_lines: total,
               truncated: more,
               next_offset: if(more, do: offset + length(kept))
             }}
        end
      end
    end)
  end

  def tail(path, opts \\ []) do
    safe(fn ->
      cap = Keyword.get(opts, :max_bytes, 16_000)
      limit = Keyword.get(opts, :limit, 200)
      unless positive(cap) and positive(limit), do: throw({:error, "positive limits required"})

      with {:ok, stat} <- File.stat(path),
           {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
        try do
          start = max(0, stat.size - cap - 4)

          chunk =
            case :file.pread(file, start, cap + 4) do
              {:ok, bytes} -> bytes
              :eof -> ""
              {:error, reason} -> throw({:error, reason})
            end

          chunk = utf8_tail(chunk)
          text2 = chunk |> lines() |> Enum.take(-limit) |> Enum.join("\n")

          text3 =
            if byte_size(text2) > cap,
              do: utf8_tail(binary_part(text2, byte_size(text2) - cap, cap)),
              else: text2

          truncated = start > 0 or text3 != String.trim_trailing(chunk, "\n")

          {:ok,
           %{
             text: text3,
             path: path,
             total_bytes: stat.size,
             total_lines: if(start == 0, do: length(lines(chunk)), else: :unknown),
             truncated: truncated,
             next:
               "read(path, offset: 1) for forward paging; increase max_bytes/limit for a larger tail"
           }}
        after
          :file.close(file)
        end
      end
    end)
  end

  def write(path, content) do
    safe(fn ->
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content),
           do: {:ok, %{path: path, bytes: IO.iodata_length(content)}}
    end)
  end

  def edit(path, old, new), do: edit(path, [{old, new}])

  def edit(path, replacements) do
    safe(fn ->
      with {:ok, text} <- File.read(path) do
        spans =
          Enum.map(replacements, fn {old, new} ->
            if old == "" or old == new, do: throw({:error, "empty or unchanged replacement"})

            case :binary.matches(text, old) do
              [{start, len}] ->
                {start, len, new}

              [] ->
                throw({:error, "not found: match exactly, including whitespace and newlines"})

              many ->
                throw({:error, "found #{length(many)} times; add context to make it unique"})
            end
          end)
          |> Enum.sort()

        Enum.chunk_every(spans, 2, 1, :discard)
        |> Enum.each(fn [{a, n, _}, {b, _, _}] ->
          if a + n > b, do: throw({:error, "overlapping replacements"})
        end)

        updated =
          Enum.reduce(Enum.reverse(spans), text, fn {a, n, replacement}, acc ->
            binary_part(acc, 0, a) <>
              replacement <> binary_part(acc, a + n, byte_size(acc) - a - n)
          end)

        with :ok <- File.write(path, updated),
             do: {:ok, %{path: path, replacements: length(spans), bytes: byte_size(updated)}}
      end
    end)
  end

  def ls(path \\ ".", opts \\ []) do
    safe(fn ->
      with {:ok, entries} <- File.ls(path) do
        limit = Keyword.get(opts, :limit, 500)
        entries = Enum.sort(entries)

        bounded(
          Enum.map(entries, fn e -> e <> if(File.dir?(Path.join(path, e)), do: "/", else: "") end),
          :entries,
          Keyword.put_new(opts, :limit, limit)
        )
      end
    end)
  end

  def find(glob, opts \\ []) do
    safe(fn ->
      limit = Keyword.get(opts, :limit, 1000)
      root = Keyword.get(opts, :cwd, ".")

      paths =
        Path.wildcard(Path.join(root, glob), match_dot: true)
        |> Enum.reject(&ignored?(&1, root, opts))
        |> Enum.sort()

      bounded(paths, :paths, Keyword.put_new(opts, :limit, limit))
    end)
  end

  def grep(pattern, opts \\ []) do
    safe(fn ->
      root = Keyword.get(opts, :path, ".")

      regex =
        if is_struct(pattern, Regex),
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

      limit = Keyword.get(opts, :limit, 100)

      matches =
        files
        |> Stream.reject(&ignored?(&1, root, opts))
        |> Stream.filter(&File.regular?/1)
        |> Stream.flat_map(fn p ->
          case File.read(p) do
            {:ok, text} ->
              text
              |> lines()
              |> Enum.with_index(1)
              |> Enum.filter(fn {l, _} -> Regex.match?(regex, l) end)
              |> Enum.map(fn {l, n} ->
                %{
                  path: p,
                  line: n,
                  text: String.slice(l, 0, Keyword.get(opts, :line_limit, 500)),
                  truncated: String.length(l) > Keyword.get(opts, :line_limit, 500)
                }
              end)

            _ ->
              []
          end
        end)
        |> Enum.take(Keyword.get(opts, :offset, 1) + limit)

      bounded(matches, :matches, Keyword.put_new(opts, :limit, limit))
    end)
  end

  def sh(command, opts \\ []) do
    with {:ok, job} <- Nano.Background.start(command, Keyword.put(opts, :notify, nil)) do
      Nano.Background.await(job.id, Keyword.get(opts, :timeout, 30_000) + 5_000)
      |> case do
        {:ok, result} ->
          with {:ok, tail} <- tail(result.path, opts), do: {:ok, Map.merge(result, tail)}

        error ->
          error
      end
    end
  end

  defp read_chunks(file, state, offset, limit, cap) do
    case :file.read(file, 8192) do
      {:ok, chunk} ->
        parts = :binary.split(chunk, "\n", [:global])

        state =
          parts
          |> Enum.with_index()
          |> Enum.reduce(state, fn {part, i}, state ->
            {kept, total, bytes, stopped, pending, size} = state
            size = size + byte_size(part)

            pending =
              if not stopped and total + 1 >= offset do
                combined = pending <> part
                binary_part(combined, 0, min(byte_size(combined), cap + 1))
              else
                ""
              end

            state = {kept, total, bytes, stopped, pending, size}
            if i < length(parts) - 1, do: finish_read_line(state, offset, limit, cap), else: state
          end)

        read_chunks(file, state, offset, limit, cap)

      :eof ->
        if elem(state, 5) > 0, do: finish_read_line(state, offset, limit, cap), else: state

      {:error, reason} ->
        throw({:error, reason})
    end
  end

  defp finish_read_line({kept, total, bytes, stopped, pending, size}, offset, limit, cap) do
    total = total + 1

    cond do
      total < offset or stopped -> {kept, total, bytes, stopped, "", 0}
      length(kept) >= limit or bytes + size + 1 > cap -> {kept, total, bytes, true, "", 0}
      true -> {[pending | kept], total, bytes + size + 1, false, "", 0}
    end
  end

  defp bounded(items, key, opts) do
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, 100)
    cap = Keyword.get(opts, :max_bytes, 16_000)

    unless positive(offset) and positive(limit) and positive(cap),
      do: throw({:error, "offset, limit and max_bytes must be positive integers"})

    selected = Enum.slice(items, offset - 1, limit)

    {kept, _} =
      Enum.reduce_while(selected, {[], 0}, fn item, {acc, size} ->
        n = byte_size(inspect(item, limit: :infinity, printable_limit: :infinity)) + 2
        if n + size <= cap, do: {:cont, {[item | acc], n + size}}, else: {:halt, {acc, size}}
      end)

    if kept == [] and selected != [],
      do: throw({:error, "first result exceeds max_bytes; increase max_bytes"})

    next = offset + length(kept)
    more = next - 1 < length(items)

    {:ok,
     %{
       key => Enum.reverse(kept),
       :truncated => more,
       :next_offset => if(more, do: next),
       :next => "repeat with offset=#{next}; increase max_bytes for oversized results"
     }}
  end

  defp utf8_tail(<<byte, rest::binary>>) when byte >= 128 and byte < 192, do: utf8_tail(rest)
  defp utf8_tail(text), do: text

  defp ignored?(path, root, opts) do
    if Keyword.get(opts, :respect_gitignore, true) and File.dir?(root) do
      relative = Path.relative_to(Path.expand(path), Path.expand(root))

      if ".git" in Path.split(relative) do
        true
      else
        case System.cmd("git", ["check-ignore", "--quiet", "--", relative],
               cd: root,
               stderr_to_stdout: true
             ) do
          {_, 0} -> true
          _ -> false
        end
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp lines(""), do: []

  defp lines(text),
    do:
      text
      |> String.split("\n")
      |> then(fn xs -> if List.last(xs) == "", do: Enum.drop(xs, -1), else: xs end)

  defp safe(fun) do
    try do
      fun.()
    rescue
      e -> {:error, Exception.message(e)}
    catch
      {:error, _} = e -> e
    end
  end
end
