defmodule Vega.Files do
  @moduledoc """
  Bounded file/shell helpers returning errors as values. read pages at 1-based offset,
  by whole lines within limit/max_bytes; next is the exact continuation (nil at EOF).
  sh keeps a byte/line bounded tail and spills complete output to path. Exact edits
  must each match once in the original, be disjoint, and change text.
  """
  def read(path, opts \\ []) do
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, 200)
    cap = Keyword.get(opts, :max_bytes, 16_000)

    if offset < 1 or limit < 1 or cap < 1 do
      {:error, :positive_offset_limit_and_max_bytes_required}
    else
      case File.open(path, [:read, :binary]) do
        {:ok, io} ->
          try do
            page(io, "", 1, offset, limit, cap, [], 0)
          after
            File.close(io)
          end

        error ->
          error
      end
    end
  end

  defp page(io, buffer, line, offset, limit, cap, acc, bytes) do
    case next_line(io, buffer, cap) do
      :eof ->
        if line < offset,
          do: {:error, {:offset_past_end, line - 1}},
          else: result(acc, nil, line - 1, false)

      {:error, reason} ->
        if acc == [], do: {:error, {reason, line}}, else: result(acc, line, nil, true)

      {:ok, text, rest} ->
        cond do
          line < offset ->
            page(io, rest, line + 1, offset, limit, cap, acc, bytes)

          length(acc) >= limit or bytes + byte_size(text) > cap ->
            result(acc, line, nil, true)

          true ->
            page(io, rest, line + 1, offset, limit, cap, [text | acc], bytes + byte_size(text))
        end
    end
  end

  defp result(acc, next, total, truncated),
    do:
      {:ok,
       %{
         text: acc |> Enum.reverse() |> IO.iodata_to_binary(),
         next: next,
         total: total,
         truncated: truncated
       }}

  defp next_line(io, buffer, cap) do
    case :binary.match(buffer, "\n") do
      {pos, 1} when pos + 1 <= cap ->
        size = pos + 1
        <<line::binary-size(^size), rest::binary>> = buffer
        {:ok, line, rest}

      {_, 1} ->
        {:error, :line_exceeds_max_bytes}

      :nomatch when byte_size(buffer) > cap ->
        {:error, :line_exceeds_max_bytes}

      :nomatch ->
        case IO.binread(io, 8192) do
          :eof -> if buffer == "", do: :eof, else: {:ok, buffer, ""}
          {:error, reason} -> {:error, reason}
          chunk -> next_line(io, buffer <> chunk, cap)
        end
    end
  end

  def write(path, text),
    do: with(:ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, text))

  def edit(path, old, new), do: edit(path, [{old, new}])

  def edit(path, replacements) when is_list(replacements) do
    with {:ok, text} <- File.read(path),
         {:ok, matches} <- matches(text, replacements),
         :ok <- disjoint(matches) do
      updated =
        Enum.reduce(Enum.sort_by(matches, &elem(&1, 0), :desc), text, fn {pos, size, new}, t ->
          binary_part(t, 0, pos) <> new <> binary_part(t, pos + size, byte_size(t) - pos - size)
        end)

      File.write(path, updated)
    end
  end

  defp matches(_, []), do: {:error, :no_replacements}

  defp matches(text, replacements) do
    Enum.reduce_while(replacements, {:ok, []}, fn {old, new}, {:ok, acc} ->
      cond do
        old == "" ->
          {:halt, {:error, :empty_match}}

        old == new ->
          {:halt, {:error, :unchanged_replacement}}

        true ->
          case occurrences(text, old, 0, []) do
            [{pos, size}] ->
              {:cont, {:ok, [{pos, size, new} | acc]}}

            [] ->
              {:halt,
               {:error, "not found: must match exactly, including whitespace and newlines"}}

            xs ->
              {:halt, {:error, "found #{length(xs)} times: add context to make it unique"}}
          end
      end
    end)
  end

  # Count overlapping occurrences too (binary.matches does not).
  defp occurrences(text, old, start, acc) when start < byte_size(text) do
    case :binary.match(text, old, scope: {start, byte_size(text) - start}) do
      :nomatch -> acc
      {pos, size} -> occurrences(text, old, pos + 1, [{pos, size} | acc])
    end
  end

  defp occurrences(_, _, _, acc), do: acc

  defp disjoint(matches) do
    matches
    |> Enum.sort()
    |> Enum.reduce_while(-1, fn {pos, size, _}, ending ->
      if pos < ending, do: {:halt, {:error, :overlapping_replacements}}, else: {:cont, pos + size}
    end)
    |> case do
      {:error, _} = e -> e
      _ -> :ok
    end
  end

  def ls(path \\ "."),
    do: with({:ok, xs} <- File.ls(path), do: {:ok, Enum.take(Enum.sort(xs), 500)})

  def find(glob), do: Enum.take(Path.wildcard(glob, match_dot: true), 1000)

  def grep(pattern, glob \\ "/app/lib/**/*.ex") do
    find(glob)
    |> Stream.flat_map(fn p ->
      File.stream!(p)
      |> Stream.with_index(1)
      |> Stream.filter(fn {l, _} -> String.contains?(l, pattern) end)
      |> Stream.map(fn {l, n} -> {p, n, String.slice(l, 0, 500)} end)
    end)
    |> Enum.take(100)
  rescue
    e -> {:error, Exception.message(e)}
  end

  def sh(cmd, opts \\ []) do
    dir = Keyword.get(opts, :output_dir, "/tmp/vega-shell")

    with :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false))
      :ok = File.write(path, "")
      started = System.monotonic_time(:millisecond)
      timeout = Keyword.get(opts, :timeout, 20_000)

      args = [
        "--kill-after=2",
        "#{timeout / 1000}s",
        "sh",
        "-c",
        "(" <> cmd <> ") >\"$1\" 2>&1",
        "vega-shell",
        path
      ]

      {diagnostic, status} =
        System.cmd("timeout", args,
          cd: Keyword.get(opts, :cwd, "/app"),
          env: Keyword.get(opts, :env, []),
          stderr_to_stdout: true
        )

      with {:ok, tail} <- tail(path, opts) do
        Map.merge(tail, %{
          status: status,
          timed_out: status in [124, 137],
          path: path,
          duration_ms: System.monotonic_time(:millisecond) - started,
          diagnostic:
            binary_part(
              diagnostic,
              max(0, byte_size(diagnostic) - 2000),
              min(2000, byte_size(diagnostic))
            )
        })
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def tail(path, opts \\ []) do
    cap = Keyword.get(opts, :max_bytes, 16_000)
    limit = Keyword.get(opts, :limit, 100)

    with true <- cap > 0 and limit > 0,
         {:ok, %{size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        start = max(0, size - cap)
        {:ok, _} = :file.position(io, start)

        chunk =
          case IO.binread(io, cap) do
            :eof -> ""
            t -> t
          end

        parts = :binary.split(chunk, "\n", [:global])
        # A trailing newline terminates a line; it is not an extra blank line.
        {parts, newline} =
          if List.last(parts) == "", do: {Enum.drop(parts, -1), "\n"}, else: {parts, ""}

        output = (parts |> Enum.take(-limit) |> Enum.join("\n")) <> newline
        {:ok, %{output: output, bytes: size, truncated: byte_size(output) < size}}
      after
        File.close(io)
      end
    else
      false -> {:error, :positive_limit_and_max_bytes_required}
      error -> error
    end
  end
end
