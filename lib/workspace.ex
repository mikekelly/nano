defmodule Workspace do
  @moduledoc """
  Bounded file and shell tools. All functions return `{:ok, value}` or `{:error, reason}`.
  `read(path, offset: 1, limit: 200, bytes: 16000)` pages lines; `tail(path)` reads the end.
  `write/2` creates parents; `edit/3` requires one exact match. `ls/2`, `find/2`, `grep/2`
  bound their listings. `sh(command, cwd: "/app", timeout: 30000)` uses Background and
  returns status, timing, output path and bounded tail. Long jobs: use Background.start/2.
  """
  def read(path, opts \\ []) do
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, 200)
    cap = Keyword.get(opts, :bytes, 16_000)

    with true <-
           is_integer(offset) and offset > 0 and is_integer(limit) and limit > 0 and
             is_integer(cap) and cap > 0,
         {:ok, text} <- File.read(path) do
      lines = String.split(text, "\n")

      if offset > length(lines) do
        {:error, "offset #{offset} past #{length(lines)} lines"}
      else
        selected = Enum.slice(lines, offset - 1, limit)

        {kept, _} =
          Enum.reduce_while(selected, {[], 0}, fn line, {acc, bytes} ->
            if bytes + byte_size(line) + 1 <= cap,
              do: {:cont, {[line | acc], bytes + byte_size(line) + 1}},
              else: {:halt, {acc, bytes}}
          end)

        n = length(kept)

        if n == 0 do
          {:error, "line #{offset} exceeds #{cap} bytes; increase bytes:"}
        else
          next = offset + n

          more =
            if next <= length(lines),
              do:
                "\n[Showing lines #{offset}-#{next - 1} of #{length(lines)}. Use offset: #{next} to continue.]",
              else: ""

          {:ok, Enum.join(Enum.reverse(kept), "\n") <> more}
        end
      end
    else
      false -> {:error, "offset, limit and bytes must be positive integers"}
      error -> error
    end
  end

  def tail(path, opts \\ []) do
    cap = Keyword.get(opts, :bytes, 16_000)

    with {:ok, f} <- :file.open(String.to_charlist(path), [:read, :binary]),
         {:ok, size} <- :file.position(f, :eof) do
      start = max(0, size - cap)
      result = :file.pread(f, start, cap)
      :file.close(f)

      case result do
        :eof ->
          {:ok, ""}

        {:ok, text} ->
          lines = String.split(text, "\n")
          selected = Enum.take(lines, -Keyword.get(opts, :limit, 200))

          marker =
            if start > 0 or length(lines) > length(selected),
              do: "[Tail truncated; full output: #{path}]\n",
              else: ""

          {:ok, marker <> Enum.join(selected, "\n")}

        error ->
          error
      end
    end
  end

  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content),
         do: {:ok, path}
  end

  def edit(path, old, new) when is_binary(old) and old != "" do
    with {:ok, text} <- File.read(path) do
      case length(:binary.matches(text, old)) do
        0 ->
          {:error, "old text not found; match exactly including whitespace and newlines"}

        1 when old == new ->
          {:error, "replacement changes nothing"}

        1 ->
          with :ok <- File.write(path, String.replace(text, old, new, global: false)),
               do: {:ok, "Updated #{path}"}

        n ->
          {:error, "old text occurs #{n} times; add context to make it unique"}
      end
    end
  end

  def edit(_, _, _), do: {:error, "old text must be nonempty"}

  def ls(path \\ ".", opts \\ []) do
    with {:ok, entries} <- File.ls(path) do
      entries =
        Enum.sort(entries)
        |> Enum.map(fn e -> e <> if(File.dir?(Path.join(path, e)), do: "/", else: "") end)

      {:ok, listing(entries, Keyword.get(opts, :limit, 500))}
    end
  end

  def find(glob, opts \\ []) do
    root = Keyword.get(opts, :cwd, "/app")

    entries =
      Path.wildcard(Path.join(root, glob), match_dot: true)
      |> Enum.map(&Path.relative_to(&1, root))

    {:ok, listing(entries, Keyword.get(opts, :limit, 1000))}
  end

  def grep(pattern, opts \\ []) do
    args =
      ["--hidden", "--line-number", "--no-heading", "--color", "never"] ++
        if(opts[:literal], do: ["-F"], else: []) ++
        if(opts[:ignore_case], do: ["-i"], else: []) ++
        if(opts[:glob], do: ["-g", opts[:glob]], else: []) ++ ["--", pattern, opts[:path] || "."]

    case System.find_executable("rg") do
      nil ->
        {:error, "ripgrep is not installed"}

      exe ->
        case System.cmd(exe, args, cd: opts[:cwd] || "/app", stderr_to_stdout: true) do
          {_, 1} ->
            {:ok, "No matches found"}

          {text, 0} ->
            lines =
              String.split(String.trim_trailing(text), "\n")
              |> Enum.map(fn l ->
                if String.length(l) > 500,
                  do: String.slice(l, 0, 500) <> " [line truncated; use read]",
                  else: l
              end)

            {:ok, listing(lines, opts[:limit] || 100)}

          {text, status} ->
            {:error, {status, String.slice(text, 0, 1000)}}
        end
    end
  end

  defp listing(entries, limit) do
    Enum.join(Enum.take(entries, limit), "\n") <>
      if(length(entries) > limit,
        do: "\n[#{limit} entries limit reached. Increase limit: to continue.]",
        else: ""
      )
  end

  def sh(command, opts \\ []) do
    with {:ok, job} <- Background.start(command, Keyword.put(opts, :notify, self())) do
      receive do
        {:background, id, result} when id == job.id ->
          with {:ok, tail} <- tail(result.path), do: {:ok, Map.put(result, :tail, tail)}
      after
        (opts[:timeout] || 30_000) + 5000 ->
          Background.cancel(job)
          {:error, :completion_timeout}
      end
    end
  end
end
