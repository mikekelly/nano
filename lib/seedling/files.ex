defmodule Seedling.Files do
  @moduledoc "Bounded file utilities. read(path, offset: 1, limit: 200, bytes: 16000); write/2; edit/3; ls/2; find/2; grep/3. Errors are values."
  def read(path, opts \\ []) do
    with {:ok, text} <- File.read(path) do
      lines = String.split(text, "\n")
      offset = Keyword.get(opts, :offset, 1)
      limit = Keyword.get(opts, :limit, 200)
      cap = Keyword.get(opts, :bytes, 16000)

      if offset < 1 or offset > length(lines) do
        {:error, "offset outside file: #{length(lines)} lines"}
      else
        chosen = Enum.slice(lines, offset - 1, limit)

        {kept, _} =
          Enum.reduce_while(chosen, {[], 0}, fn line, {acc, n} ->
            if n + byte_size(line) + 1 > cap,
              do: {:halt, {acc, n}},
              else: {:cont, {[line | acc], n + byte_size(line) + 1}}
          end)

        next = offset + length(kept)

        {:ok,
         %{
           text: Enum.reverse(kept) |> Enum.join("\n"),
           next_offset: if(next <= length(lines), do: next),
           total_lines: length(lines),
           warning: if(kept == [], do: "Single line exceeds byte cap; raise bytes")
         }}
      end
    end
  end

  def write(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, text)
  end

  def edit(path, old, new) do
    with {:ok, text} <- File.read(path) do
      case length(:binary.matches(text, old)) do
        1 when old != new ->
          File.write(path, String.replace(text, old, new, global: false))

        n ->
          {:error,
           "Expected exactly one match and a change, found #{n}; add unique exact context"}
      end
    end
  end

  def ls(path, opts \\ []) do
    with {:ok, entries} <- File.ls(path) do
      limit = Keyword.get(opts, :limit, 500)

      {:ok,
       %{
         entries:
           entries
           |> Enum.sort()
           |> Enum.take(limit)
           |> Enum.map(fn p -> p <> if(File.dir?(Path.join(path, p)), do: "/", else: "") end),
         truncated: length(entries) > limit
       }}
    end
  end

  @doc "Gitignore-aware glob search via rg. Hidden files included, .git excluded."
  def find(glob, opts \\ []) do
    parts = Path.split(glob)
    prefix = Enum.take_while(parts, &(not String.contains?(&1, ["*", "?", "[", "{"])))
    prefix = if length(prefix) == length(parts), do: Enum.drop(prefix, -1), else: prefix
    base = if prefix == [], do: ".", else: Path.join(prefix)
    pattern = parts |> Enum.drop(length(prefix)) |> Path.join()
    limit = Keyword.get(opts, :limit, 1000)

    with {:ok, result} <-
           rg(
             ["--files", "--hidden", "-g", "!.git", "-g", pattern, "."],
             base,
             limit,
             Keyword.put(opts, :line_bytes, 4096)
           ) do
      paths =
        result.text
        |> String.split("\n", trim: true)
        |> Enum.map(fn p ->
          p = String.trim_leading(p, "./")
          if base == ".", do: p, else: Path.join(base, p)
        end)

      {:ok, %{paths: paths, truncated: result.truncated}}
    end
  end

  @doc "Globally bounded streaming matches, not rg's per-file --max-count."
  def grep(pattern, path \\ "/app", opts \\ []) do
    args =
      ["--hidden", "--color", "never", "-n", "-g", "!.git"] ++
        if(Keyword.get(opts, :literal, false), do: ["-F"], else: []) ++
        if(Keyword.get(opts, :ignore_case, false), do: ["-i"], else: []) ++
        case Keyword.get(opts, :glob) do
          nil -> []
          glob -> ["-g", glob]
        end ++ ["--", pattern, path]

    rg(args, Keyword.get(opts, :cwd, "."), Keyword.get(opts, :limit, 100), opts)
  end

  defp rg(args, cwd, limit, opts) when is_integer(limit) and limit > 0 do
    case System.find_executable("rg") do
      nil ->
        {:error, "rg executable missing; install ripgrep"}

      exe ->
        cap = Keyword.get(opts, :bytes, 16_000)
        timeout = Keyword.get(opts, :timeout, 5000)

        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args},
            {:cd, Path.expand(cwd)}
          ])

        deadline = System.monotonic_time(:millisecond) + timeout

        try do
          collect(port, "", limit, cap, deadline, Keyword.get(opts, :line_bytes, 500))
        after
          if Port.info(port), do: Port.close(port)
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp rg(_, _, _, _), do: {:error, "limit must be a positive integer"}

  defp collect(port, acc, limit, cap, deadline, line_cap) do
    receive do
      {^port, {:data, data}} ->
        next = acc <> data
        count = length(:binary.matches(next, "\n"))

        if byte_size(next) > cap or count > limit do
          finish(binary_part(next, 0, min(byte_size(next), cap)), nil, true, limit, line_cap)
        else
          collect(port, next, limit, cap, deadline, line_cap)
        end

      {^port, {:exit_status, status}} ->
        if status in [0, 1],
          do: finish(acc, status, false, limit, line_cap),
          else: {:error, %{status: status, text: acc}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, %{reason: :timeout, text: acc}}
    end
  end

  defp finish(text, status, truncated, limit, line_cap) do
    text =
      if truncated and line_cap > 500 and not String.ends_with?(text, "\n") do
        case :binary.matches(text, "\n") |> List.last() do
          nil -> ""
          {at, _} -> binary_part(text, 0, at + 1)
        end
      else
        text
      end

    lines = String.split(text, "\n", trim: true)

    long = Enum.any?(lines, &(byte_size(&1) > line_cap))
    kept = lines |> Enum.take(limit) |> Enum.map(&safe_prefix(&1, line_cap)) |> Enum.join("\n")

    {:ok,
     %{
       text: kept,
       status: status,
       truncated: truncated or long,
       notice:
         if(truncated or long,
           do:
             "Output capped globally (matches, bytes or line-length limit); refine search or raise limit/bytes and read matching files",
           else: nil
         )
     }}
  end

  defp safe_prefix(text, cap) do
    # Binary truncation may split UTF-8; scrub incomplete/invalid sequences.
    prefix = binary_part(text, 0, min(byte_size(text), cap))
    prefix |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
  end
end
