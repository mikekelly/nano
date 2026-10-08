defmodule Workspace do
  @moduledoc """
  Bounded file and shell tools returning `{:ok, value}` or `{:error, reason}`.

  * `read(path, offset: 1, limit: 200, bytes: 16000)` streams a page of lines, keeping
    the head. It reports the next offset and refuses an individual oversized line.
    Empty files have zero lines; a trailing newline does not create an extra line.
  * `tail(path, limit: 200, bytes: 16000)` seeks to the end, keeping bounded output.
  * `write/2` creates parents; `edit/3` requires one exact match and limits files to 8 MiB.
  * `ls(path, limit: 500, bytes: 16000)` lists sorted entries, including dotfiles.
  * `find(glob, cwd: "/app")` lists files (not directories). Globs support `*`, `**`, `?`, character
    classes and `{a,b}` alternatives; a glob without `/` matches basenames recursively.
  * `grep(pattern, cwd: "/app", path: ".", literal: false, ignore_case: false,
    glob: "*.ex", limit: 100)` searches with ripgrep; lines are previewed at 500 columns.
    Find/search include hidden files, exclude .git, and respect .gitignore/.ignore even
    outside a Git repository. `no_ignore: true` disables ignore files, not .git exclusion.
    Both require `rg`; their full output is spooled to disk rather than accumulated in RAM.
    Globs filter after ignore traversal, so never override ignores. Paths with newlines
    (or colons for grep) are not supported by the text result format.
  * `sh(command, cwd: "/app", timeout: 20000, limit: 200, bytes: 16000)` uses Background;
    returns status, timing, full-output path and bounded tail. The 20s default leaves cleanup
    room inside the harness's 30s eval deadline. Long jobs: Background.start/2.

  Text is byte-oriented (binary files are not decoded); caps count bytes before explanatory
  markers. Explicit limits may be raised. Search/shell output files are retained for callers
  to manage. Paging bounds memory, not the time needed to skip to a distant line. Listings
  sort directory entries in memory; edit is an exact, non-atomic whole-file operation.
  """

  def read(path, opts \\ []) do
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, 200)
    cap = Keyword.get(opts, :bytes, 16_000)

    with :ok <- positive_options(offset: offset, limit: limit, bytes: cap),
         {:ok, f} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        state = %{line: 0, kept: [], bytes: 0, count: 0, next: nil, error: nil}

        case scan_lines(f, cap, state, fn text, size, s ->
               line = s.line + 1
               s = %{s | line: line}
               cost = size + if(s.count > 0, do: 1, else: 0)

               cond do
                 line < offset ->
                   {:cont, s}

                 s.count >= limit ->
                   {:halt, %{s | next: line}}

                 size > cap and s.count == 0 ->
                   {:halt, %{s | error: "line #{line} exceeds #{cap} bytes; increase bytes:"}}

                 s.bytes + cost > cap ->
                   {:halt, %{s | next: line}}

                 true ->
                   {:cont,
                    %{s | kept: [text | s.kept], bytes: s.bytes + cost, count: s.count + 1}}
               end
             end) do
          {:ok, %{error: error}} when not is_nil(error) ->
            {:error, error}

          {:ok, %{line: 0}} when offset == 1 ->
            {:ok, ""}

          {:ok, %{line: n}} when n < offset ->
            {:error, "offset #{offset} past #{n} lines"}

          {:ok, s} ->
            more =
              if s.next,
                do:
                  "\n[Showing lines #{offset}-#{s.next - 1}. Use offset: #{s.next} to continue.]",
                else: ""

            {:ok, Enum.join(Enum.reverse(s.kept), "\n") <> more}

          error ->
            error
        end
      after
        :file.close(f)
      end
    end
  end

  # Chunks and individual line buffers are bounded even for a multi-gigabyte single line.
  defp scan_lines(f, cap, state, fun, pending \\ "", size \\ 0) do
    case :file.read(f, 8192) do
      {:ok, chunk} ->
        consume_lines(f, cap, state, fun, pending, size, :binary.split(chunk, "\n", [:global]))

      :eof ->
        if size > 0 do
          {_, state} = fun.(pending, size, state)
          {:ok, state}
        else
          {:ok, state}
        end

      error ->
        error
    end
  end

  defp consume_lines(f, cap, state, fun, pending, size, [last]) do
    pending = bounded_append(pending, last, cap)
    size = size + byte_size(last)
    # A selected oversized line can halt immediately; skipped lines must still be counted
    # at their actual newline. Callbacks are pure, so discard a speculative :cont state.
    if size > cap do
      case fun.(pending, size, state) do
        {:halt, state} -> {:ok, state}
        {:cont, _} -> scan_lines(f, cap, state, fun, pending, size)
      end
    else
      scan_lines(f, cap, state, fun, pending, size)
    end
  end

  defp consume_lines(f, cap, state, fun, pending, size, [line | rest]) do
    case fun.(bounded_append(pending, line, cap), size + byte_size(line), state) do
      {:halt, state} -> {:ok, state}
      {:cont, state} -> consume_lines(f, cap, state, fun, "", 0, rest)
    end
  end

  defp bounded_append(a, b, cap),
    do: a <> binary_part(b, 0, min(byte_size(b), max(0, cap - byte_size(a))))

  def tail(path, opts \\ []) do
    cap = Keyword.get(opts, :bytes, 16_000)
    limit = Keyword.get(opts, :limit, 200)

    with :ok <- positive_options(bytes: cap, limit: limit),
         {:ok, f} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, size} <- :file.position(f, :eof) do
          start = max(0, size - cap)

          case :file.pread(f, start, cap) do
            :eof ->
              {:ok, ""}

            {:ok, text} ->
              # Keep trailing newline without counting it as a phantom line.
              newline = if String.ends_with?(text, "\n"), do: "\n", else: ""
              lines = String.split(String.trim_trailing(text, "\n"), "\n")
              # Remove only one newline, preserving blank lines at the end.
              lines =
                if newline == "\n",
                  do: :binary.split(binary_part(text, 0, byte_size(text) - 1), "\n", [:global]),
                  else: lines

              selected = Enum.take(lines, -limit)

              marker =
                if start > 0 or length(lines) > length(selected),
                  do: "[Tail truncated; full output: #{path}]\n",
                  else: ""

              {:ok, marker <> Enum.join(selected, "\n") <> newline}

            error ->
              error
          end
        end
      after
        :file.close(f)
      end
    end
  end

  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content),
         do: {:ok, path}
  end

  def edit(path, old, new) when is_binary(old) and old != "" and is_binary(new) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= 8_388_608,
         {:ok, text} <- File.read(path) do
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
    else
      false -> {:error, "edit is limited to 8 MiB files; use a streaming transformation"}
      error -> error
    end
  end

  def edit(_, _, _), do: {:error, "old text must be nonempty and replacement must be a string"}

  def ls(path \\ ".", opts \\ []) do
    with :ok <- limits(opts, 500), {:ok, entries} <- File.ls(path) do
      entries =
        Enum.sort(entries)
        |> Enum.map(fn e -> e <> if(File.dir?(Path.join(path, e)), do: "/", else: "") end)

      {:ok, listing(entries, opts, 500, "(empty directory)")}
    end
  end

  def find(glob, opts \\ []) do
    with {:ok, filter} <- glob_regex(glob) do
      rg(["--files"], opts, 1000, "No files found matching pattern", filter, :files)
    end
  end

  def grep(pattern, opts \\ []) do
    with {:ok, filter} <- glob_regex(opts[:glob] || "**") do
      args =
        [
          "--line-number",
          "--with-filename",
          "--no-heading",
          "--color",
          "never",
          "--max-columns",
          "500",
          "--max-columns-preview"
        ] ++
          if(opts[:literal], do: ["-F"], else: []) ++
          if(opts[:ignore_case], do: ["-i"], else: []) ++
          ["--", pattern, opts[:path] || "."]

      rg(args, opts, 100, "No matches found", filter, :matches)
    end
  end

  defp rg(args, opts, default, empty, filter, kind) do
    with :ok <- limits(opts, default),
         exe when is_binary(exe) <- System.find_executable("rg") do
      # Positive rg --glob rules override ignore files! Filter AFTER traversal instead.
      common =
        ["--hidden", "--no-require-git", "--glob", "!.git", "--glob", "!.git/**"] ++
          if(opts[:no_ignore], do: ["--no-ignore"], else: [])

      command = Enum.map_join([exe | common ++ args], " ", &quote_sh/1)

      case sh(command, Keyword.put_new(opts, :timeout, 10_000)) do
        {:ok, %{status: 1}} ->
          {:ok, empty}

        {:ok, %{status: 0, path: path}} ->
          search_page(path, opts, default, empty, filter, kind)

        {:ok, %{status: status, tail: text, path: path}} ->
          {:error, %{status: status, message: text, path: path}}

        error ->
          error
      end
    else
      nil -> {:error, "ripgrep (rg) is required; install it to use find/grep"}
      error -> error
    end
  end

  defp search_page(path, opts, default, empty, filter, kind) do
    cap = Keyword.get(opts, :bytes, 16_000)
    limit = Keyword.get(opts, :limit, default)

    with {:ok, file} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        state = %{kept: [], count: 0, bytes: 0, cut: false}

        {:ok, s} =
          scan_lines(file, max(cap, 8192), state, fn line, size, s ->
            name = if kind == :files, do: line, else: hd(:binary.split(line, ":"))

            name =
              name
              |> Path.relative_to(Path.expand(opts[:cwd] || "/app"))
              |> String.trim_leading("./")

            cond do
              not Regex.match?(filter, name) ->
                {:cont, s}

              s.count >= limit or s.bytes + size + 1 > cap ->
                {:halt, %{s | cut: true}}

              true ->
                {:cont,
                 %{s | kept: [line | s.kept], count: s.count + 1, bytes: s.bytes + size + 1}}
            end
          end)

        cond do
          s.count == 0 and not s.cut ->
            {:ok, empty}

          true ->
            cut =
              if s.cut,
                do: "Results truncated; increase limit: #{limit}, bytes: #{cap}. ",
                else: ""

            preview =
              if kind == :matches,
                do: " Lines previewed at 500 columns; read source for full lines.",
                else: ""

            {:ok,
             Enum.join(Enum.reverse(s.kept), "\n") <>
               "\n[#{cut}Full unfiltered results: #{path}; use read/2 to page.#{preview}]"}
        end
      after
        :file.close(file)
      end
    end
  end

  # Glob filtering cannot re-include files excluded by rg's ignore traversal.
  defp glob_regex(glob) when is_binary(glob) do
    prefix = if String.contains?(glob, "/"), do: "", else: "(?:.*/)?"

    case glob_parts(String.graphemes(String.trim_leading(glob, "./")), 0) do
      {:ok, parts} ->
        case Regex.compile("^" <> prefix <> IO.iodata_to_binary(parts) <> "$") do
          {:ok, regex} -> {:ok, regex}
          {:error, _} -> {:error, :invalid_glob}
        end

      error ->
        error
    end
  end

  defp glob_regex(_), do: {:error, :invalid_glob}
  defp glob_parts([], 0), do: {:ok, []}
  defp glob_parts([], _), do: {:error, :invalid_glob}
  defp glob_parts(["*", "*", "/" | rest], n), do: glob_part("(?:.*/)?", rest, n)
  defp glob_parts(["*", "*" | rest], n), do: glob_part(".*", rest, n)
  defp glob_parts(["*" | rest], n), do: glob_part("[^/]*", rest, n)
  defp glob_parts(["?" | rest], n), do: glob_part("[^/]", rest, n)
  defp glob_parts(["{" | rest], n), do: glob_part("(?:", rest, n + 1)
  defp glob_parts(["}" | rest], n) when n > 0, do: glob_part(")", rest, n - 1)
  defp glob_parts(["," | rest], n) when n > 0, do: glob_part("|", rest, n)
  defp glob_parts(["\\", char | rest], n), do: glob_part(Regex.escape(char), rest, n)

  defp glob_parts(["[" | rest], n) do
    case Enum.split_while(rest, &(&1 != "]")) do
      {[], _} ->
        {:error, :invalid_glob}

      {_, []} ->
        {:error, :invalid_glob}

      {chars, [_ | rest]} ->
        chars =
          case chars do
            ["!" | tail] -> ["^" | tail]
            other -> other
          end

        glob_part(["[", chars, "]"], rest, n)
    end
  end

  defp glob_parts([char | rest], n), do: glob_part(Regex.escape(char), rest, n)

  defp glob_part(part, rest, n) do
    with {:ok, parts} <- glob_parts(rest, n), do: {:ok, [part | parts]}
  end

  defp quote_sh(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp limits(opts, default),
    do:
      positive_options(
        limit: Keyword.get(opts, :limit, default),
        bytes: Keyword.get(opts, :bytes, 16_000)
      )

  defp positive_options(opts) do
    case Enum.find(opts, fn {_, n} -> not (is_integer(n) and n > 0) end) do
      nil -> :ok
      {key, _} -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp listing(entries, opts, default, empty) do
    limit = Keyword.get(opts, :limit, default)
    cap = Keyword.get(opts, :bytes, 16_000)

    {selected, _, cut} =
      Enum.reduce_while(entries, {[], 0, false}, fn entry, {acc, bytes, _} ->
        if length(acc) < limit and bytes + byte_size(entry) + 1 <= cap,
          do: {:cont, {[entry | acc], bytes + byte_size(entry) + 1, false}},
          else: {:halt, {acc, bytes, true}}
      end)

    if entries == [] do
      empty
    else
      Enum.join(Enum.reverse(selected), "\n") <>
        if(cut,
          do:
            "\n[Listing truncated at limit: #{limit}, bytes: #{cap}. Increase limit:/bytes: or narrow the directory.]",
          else: ""
        )
    end
  end

  def sh(command, opts \\ []) do
    opts = Keyword.put_new(opts, :timeout, 20_000)

    with :ok <- limits(opts, 200),
         {:ok, job} <- Background.start(command, Keyword.put(opts, :notify, self())) do
      receive do
        {:background, id, result} when id == job.id ->
          with {:ok, tail} <- tail(result.path, opts), do: {:ok, Map.put(result, :tail, tail)}
      after
        opts[:timeout] + 5000 ->
          Background.cancel(job)
          {:error, :completion_timeout}
      end
    end
  end
end
