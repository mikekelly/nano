defmodule Seedling.Files do
  @moduledoc "Bounded file tools. Zero-based read offsets; errors returned, paths unrestricted."

  def read(path, opts \\ []) do
    protect(fn ->
      offset = Keyword.get(opts, :offset, 0)
      limit = bound(opts, :lines, 100, 500)
      cap = bound(opts, :bytes, 12000, 24000)

      if not is_integer(offset) or offset < 0,
        do: raise(ArgumentError, "offset must be a nonnegative line index")

      total = Enum.count(File.stream!(path))

      if offset > total do
        {:error, {:offset_past_end, offset, total}}
      else
        lines = File.stream!(path) |> Stream.drop(offset) |> Enum.take(limit + 1)

        {kept, bytes} =
          Enum.reduce_while(Enum.take(lines, limit), {[], 0}, fn line, {acc, size} ->
            if size + byte_size(line) <= cap,
              do: {:cont, {[line | acc], size + byte_size(line)}},
              else: {:halt, {acc, size}}
          end)

        count = length(kept)

        if count == 0 and lines != [] do
          {:error, {:line_exceeds_cap, offset, byte_size(hd(lines)), cap}}
        else
          next = offset + count

          {:ok,
           %{
             text: kept |> Enum.reverse() |> Enum.join(),
             offset: offset,
             next_offset: next,
             more: next < total,
             clipped: count < min(length(lines), limit),
             total_lines: total,
             bytes: bytes,
             continuation: if(next < total, do: "Use offset=#{next} to continue", else: nil)
           }}
        end
      end
    end)
  end

  def write(path, content) do
    protect(fn -> with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, content) end)
  end

  # Preserve single-edit success/error shapes. Multi-edit matches the ORIGINAL file.
  def edit(path, old, new) do
    case edit(path, [{old, new}]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def edit(path, edits) do
    protect(fn ->
      with {:ok, content} <- File.read(path), {:ok, ranges} <- ranges(content, edits) do
        result =
          Enum.reduce(Enum.sort_by(ranges, &elem(&1, 0), :desc), content, fn {start, size, new},
                                                                             text ->
            binary_part(text, 0, start) <>
              new <> binary_part(text, start + size, byte_size(text) - start - size)
          end)

        with :ok <- File.write(path, result) do
          diff =
            Enum.map_join(ranges, "\n", fn {start, size, new} ->
              "@@ byte #{start} @@\n-" <>
                String.slice(binary_part(content, start, size), 0, 1000) <>
                "\n+" <> String.slice(new, 0, 1000)
            end)

          {:ok,
           %{
             changes: length(ranges),
             diff: String.slice(diff, 0, 4000),
             clipped:
               String.length(diff) > 4000 or
                 Enum.any?(ranges, fn {_, size, new} ->
                   size > 1000 or String.length(new) > 1000
                 end)
           }}
        end
      end
    end)
  end

  defp ranges(content, edits) when is_list(edits) do
    Enum.reduce_while(edits, {:ok, []}, fn
      {old, new}, {:ok, acc} when is_binary(old) and is_binary(new) and old != "" ->
        case :binary.matches(content, old) do
          [{start, size}] ->
            cond do
              old == new ->
                {:halt, {:error, :no_change}}

              Enum.any?(acc, fn {s, n, _} -> start < s + n and s < start + size end) ->
                {:halt, {:error, :overlapping_edits}}

              true ->
                {:cont, {:ok, [{start, size, new} | acc]}}
            end

          matches ->
            {:halt, {:error, {:expected_one_match, length(matches)}}}
        end

      _, _ ->
        {:halt, {:error, :invalid_edit}}
    end)
    |> case do
      {:ok, []} -> {:error, :no_change}
      result -> result
    end
  end

  defp ranges(_, _), do: {:error, :invalid_edits}

  def ls(path \\ ".", opts \\ []) do
    protect(fn ->
      with {:ok, entries} <- File.ls(path) do
        entries =
          Enum.sort(entries)
          |> Enum.map(fn name ->
            if File.dir?(Path.join(path, name)), do: name <> "/", else: name
          end)

        bounded(entries, opts, 500)
      end
    end)
  end

  def find(glob, opts \\ []) do
    protect(fn -> bounded(paths(glob, opts), opts, 1000) end)
  end

  def grep(pattern, opts \\ []) do
    protect(fn ->
      matcher =
        cond do
          is_struct(pattern, Regex) ->
            if Keyword.get(opts, :ignore_case, false),
              do:
                Regex.compile!(
                  Regex.source(pattern),
                  Enum.uniq([:caseless | Regex.opts(pattern)])
                ),
              else: pattern

          is_binary(pattern) ->
            Regex.compile!(
              Regex.escape(pattern),
              if(Keyword.get(opts, :ignore_case, false), do: "i", else: "")
            )

          true ->
            raise ArgumentError, "pattern must be a literal binary or Regex"
        end

      limit = bound(opts, :limit, 100, 500)
      context = Keyword.get(opts, :context, 0) |> max(0) |> min(5)

      hits =
        paths(Keyword.get(opts, :glob, "/app/lib/**/*.ex"), opts)
        |> Stream.filter(&File.regular?/1)
        |> Stream.flat_map(fn path ->
          if context == 0 do
            File.stream!(path)
            |> Stream.with_index(1)
            |> Stream.filter(fn {line, _} -> Regex.match?(matcher, line) end)
            |> Stream.map(fn {line, n} -> match(path, line, n) end)
          else
            lines = Enum.to_list(File.stream!(path))

            lines
            |> Stream.with_index(1)
            |> Stream.filter(fn {line, _} -> Regex.match?(matcher, line) end)
            |> Stream.map(fn {line, n} ->
              Map.merge(match(path, line, n), %{
                before: context_lines(lines, max(1, n - context), n - 1),
                after: context_lines(lines, n + 1, min(length(lines), n + context))
              })
            end)
          end
        end)
        |> Enum.take(limit + 1)

      {:ok, %{matches: Enum.take(hits, limit), more: length(hits) > limit}}
    end)
  end

  defp match(path, line, n) do
    %{path: path, line: n, text: String.slice(line, 0, 500), clipped: String.length(line) > 500}
  end

  defp context_lines(_, first, last) when first > last, do: []

  defp context_lines(lines, first, last) do
    Enum.map(first..last, fn n ->
      %{line: n, text: String.slice(Enum.at(lines, n - 1), 0, 500)}
    end)
  end

  # Git owns ignore semantics (nested rules, negations and worktrees). No shell interpolation.
  defp paths(glob, opts) do
    paths = Path.wildcard(glob, match_dot: Keyword.get(opts, :dotfiles, false))

    if Keyword.get(opts, :gitignore, true) and not File.regular?(glob) do
      paths
      |> Enum.group_by(&git_root/1)
      |> Enum.flat_map(fn
        {nil, files} ->
          files

        {root, files} ->
          Enum.reject(files, fn file ->
            {_, status} =
              System.cmd(
                "git",
                ["-C", root, "check-ignore", "--no-index", "-q", "--", Path.expand(file)],
                stderr_to_stdout: true
              )

            status == 0
          end)
      end)
      |> Enum.sort()
    else
      paths
    end
  end

  defp git_root(path) do
    path = Path.expand(path)

    cond do
      File.exists?(Path.join(path, ".git")) -> path
      Path.dirname(path) == path -> nil
      true -> git_root(Path.dirname(path))
    end
  end

  def tail(path, opts \\ []) do
    protect(fn ->
      cap = bound(opts, :bytes, 12000, 24000)
      want = bound(opts, :lines, 100, 500)

      with {:ok, stat} <- File.stat(path) do
        File.open!(path, [:read, :binary], fn io ->
          start = max(0, stat.size - cap)
          {:ok, _} = :file.position(io, start)

          raw =
            case IO.binread(io, cap) do
              :eof -> ""
              data -> data
            end

          # Keep newline delimiters to preserve exact shell output, including final newline.
          lines = Regex.scan(~r/[^\n]*\n|[^\n]+\z/s, raw) |> Enum.map(&hd/1)
          text = lines |> Enum.take(-want) |> Enum.join()
          total = Enum.count(File.stream!(path))
          shown = min(length(lines), want)

          {:ok,
           %{
             text: text,
             bytes: stat.size,
             path: path,
             clipped: start > 0 or length(lines) > want,
             lines: shown,
             total_lines: total,
             from_line: max(1, total - shown + 1),
             to_line: total
           }}
        end)
      end
    end)
  end

  defp bounded(entries, opts, max) do
    cap = bound(opts, :limit, 200, max)
    {:ok, %{entries: Enum.take(entries, cap), more: length(entries) > cap}}
  end

  defp bound(opts, key, default, max), do: Keyword.get(opts, key, default) |> min(max) |> max(1)

  defp protect(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  end
end
