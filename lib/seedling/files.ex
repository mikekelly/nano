defmodule Seedling.Files do
  @moduledoc """
  Small, bounded file tools. Every API returns `{:ok, map}` or
  `{:error, %{reason: reason, message: actionable_text}}`. Maps contain compact
  `:text` for display and metadata for branching; cuts always include a `:notice`.

      Seedling.Files.read("lib/example.ex", offset: 1, limit: 100)
      Seedling.Files.write("tmp/example.txt", "hello\n")
      Seedling.Files.edit("tmp/example.txt", "hello", "goodbye")
      Seedling.Files.edit("tmp/example.txt", [{"goodbye", "hello"}, {"other", "new"}])
      Seedling.Files.ls("lib")
      Seedling.Files.find("**/*_test.exs", cwd: ".")
      Seedling.Files.grep("defmodule", path: "lib", glob: "*.ex", literal: true)

  Reads keep the head, page by 1-based line offset, and default to 200 lines/16 KB.
  A line exceeding the byte cap is an explicit error (increase `:max_bytes`). Empty
  files at offset 1 succeed; past-end offsets report total lines. Binary/non-UTF-8
  reads are rejected; use File.read/1 for raw data.

  Writes create parents and atomically rename a sibling temporary file. Edits
  match each replacement against the original, require exactly one occurrence,
  reject overlaps and no-ops, preserve CRLF, and return a bounded change preview.
  Edits are limited to 2 MB by default (`:max_file_bytes`). Concurrent writers are
  not locked; callers must coordinate ownership. Symlinks are followed by reads,
  but refused by writes/edits to avoid replacing a link unexpectedly.

  `find/2` and `grep/2` use ripgrep (install `ripgrep` if missing). They respect
  ignore files even outside Git repositories, include hidden files, do not follow
  directory symlinks, and exclude `.git/`. Options `:cwd` for find, `:path` for grep,
  `:glob`, `:limit` (500 entries/100 matches), `:max_bytes` (16 KB), and grep
  `:literal`, `:ignore_case`, `:context`, `:max_line_chars` (500). Lists include
  `:entries`; grep includes `:matches` and context entries. Empty searches succeed.
  Search output is streamed from a shell spool, so large results do not enter
  context; the complete machine output is at `:output_path`.
  """

  alias Seedling.Shell
  alias Seedling.Files.Edit

  @doc "Read a bounded page, with next_offset when more lines remain."
  def read(path, opts \\ []) do
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, 200)
    cap = Keyword.get(opts, :max_bytes, 16_000)

    if positive?(offset) and positive?(limit) and positive?(cap) do
      with {:ok, io} <- File.open(path, [:read, :binary]) do
        result = read_lines(io, path, offset, limit, cap, 0, [], 0, nil)
        File.close(io)
        result
      else
        {:error, reason} -> file_error(:read, path, reason)
      end
    else
      error(
        :invalid_options,
        "offset, limit and max_bytes must be positive integers; offset is 1-based."
      )
    end
  end

  defp read_lines(io, path, offset, limit, cap, count, kept, bytes, issue, buffer \\ "") do
    case next_line(io, buffer, cap, [], 0) do
      {:line, line, rest} ->
        n = count + 1

        {kept, bytes, issue} =
          cond do
            n < offset or issue != nil or length(kept) >= limit ->
              {kept, bytes, issue}

            match?({:too_long, _}, line) ->
              {:too_long, size} = line
              {kept, bytes, {:line_too_long, n, size}}

            not String.valid?(line) or String.contains?(line, <<0>>) ->
              {kept, bytes, {:binary_file, n}}

            bytes + byte_size(line) > cap ->
              {kept, bytes, :byte_limit}

            true ->
              {[line | kept], bytes + byte_size(line), nil}
          end

        read_lines(io, path, offset, limit, cap, n, kept, bytes, issue, rest)

      :eof ->
        cond do
          match?({:binary_file, _}, issue) ->
            error(
              :binary_file,
              "#{path} contains binary or invalid UTF-8 data; use File.read/1 for raw bytes."
            )

          match?({:line_too_long, _, _}, issue) ->
            {:line_too_long, line, size} = issue

            error(
              :line_too_long,
              "Line #{line} of #{path} is #{size} bytes; increase max_bytes to at least #{size} or use raw File IO."
            )

          offset > max(count, 1) ->
            error(
              :offset_past_end,
              "Offset #{offset} is past the end of #{path} (#{count} lines); use offset <= #{max(count, 1)}."
            )

          true ->
            shown = length(kept)
            next = offset + shown
            cut = next <= count

            {:ok,
             %{
               path: path,
               text: kept |> Enum.reverse() |> IO.iodata_to_binary(),
               offset: offset,
               shown_lines: shown,
               total_lines: count,
               bytes: bytes,
               truncated: cut,
               next_offset: if(cut, do: next, else: nil),
               notice:
                 if(cut,
                   do:
                     "Showing lines #{offset}-#{next - 1} of #{count}. Use offset: #{next} to continue.",
                   else: nil
                 )
             }}
        end

      {:error, reason} ->
        file_error(:read, path, reason)
    end
  end

  # Unlike :file.read_line this preserves CRLF, and never buffers an unbounded line.
  defp next_line(io, buffer, cap, acc, seen) do
    case :binary.match(buffer, "\n") do
      {pos, 1} ->
        size = seen + pos + 1

        line =
          if size > cap,
            do: {:too_long, size},
            else: IO.iodata_to_binary(Enum.reverse([binary_part(buffer, 0, pos + 1) | acc]))

        {:line, line, binary_part(buffer, pos + 1, byte_size(buffer) - pos - 1)}

      :nomatch ->
        size = seen + byte_size(buffer)
        acc = if size <= cap, do: [buffer | acc], else: []

        case IO.binread(io, 65_536) do
          :eof when size == 0 ->
            :eof

          :eof ->
            {:line,
             if(size > cap, do: {:too_long, size}, else: IO.iodata_to_binary(Enum.reverse(acc))),
             ""}

          {:error, reason} ->
            {:error, reason}

          data ->
            next_line(io, data, cap, acc, size)
        end
    end
  end

  @doc "Create or atomically rewrite a file; parent directories are created."
  def write(path, content) when is_binary(content) do
    with :ok <- writable(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_write(path, content) do
      {:ok,
       %{
         path: path,
         bytes: byte_size(content),
         text: "Wrote #{byte_size(content)} bytes to #{path}."
       }}
    else
      {:error, %{reason: _}} = error -> error
      {:error, reason} -> file_error(:write, path, reason)
    end
  end

  def write(_path, _content), do: error(:invalid_content, "Content must be a binary/string.")

  @doc "Replace unique exact text, or apply a list of disjoint {old, new} edits with options."
  def edit(path, replacements_or_old, opts_or_new \\ [])

  def edit(path, old, new) when is_binary(old) and is_binary(new),
    do: edit(path, [{old, new}], [])

  def edit(path, replacements, opts) when is_list(replacements) and is_list(opts) do
    cap = Keyword.get(opts, :max_file_bytes, 2_000_000)

    with :ok <- writable(path),
         {:ok, stat} <- File.stat(path),
         :ok <-
           if(positive?(cap) and stat.size <= cap,
             do: :ok,
             else:
               error(
                 :file_too_large,
                 "#{path} is #{stat.size} bytes; use a larger max_file_bytes (positive integer)."
               )
           ),
         {:ok, original} <- File.read(path),
         {:ok, changed, preview, tolerant} <- Edit.apply(original, replacements, opts),
         :ok <- atomic_write(path, changed) do
      {:ok,
       %{
         path: path,
         bytes: byte_size(changed),
         replacements: length(replacements),
         tolerant: tolerant,
         text: preview.text,
         truncated: preview.truncated,
         notice: preview.notice
       }}
    else
      {:error, %{reason: _}} = error -> error
      {:error, reason} -> file_error(:edit, path, reason)
    end
  end

  @doc "List a directory, including dotfiles, sorted and marking directories with /."
  def ls(path \\ ".", opts \\ []) do
    with {:ok, names} <- File.ls(path) do
      entries =
        names
        |> Enum.sort()
        |> Enum.map(fn name ->
          name <> if(File.dir?(Path.join(path, name)), do: "/", else: "")
        end)

      bounded_entries(
        entries,
        path,
        Keyword.get(opts, :limit, 500),
        Keyword.get(opts, :max_bytes, 16_000),
        "(empty directory)"
      )
    else
      {:error, reason} -> file_error(:list, path, reason)
    end
  end

  @doc "Find files by glob. Paths are relative to cwd, without leading ./; no directories."
  def find(glob, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")

    with :ok <- search_options(opts, 500),
         {:ok, result} <-
           rg(
             [
               "--files",
               "--null",
               "--hidden",
               "--no-require-git",
               "-g",
               "!.git",
               "--type-add",
               "seedling:" <> glob,
               "-t",
               "seedling",
               "--",
               "."
             ],
             cwd,
             opts
           ),
         {:ok, io} <- File.open(result.output_path, [:read, :binary]) do
      stream =
        Stream.resource(fn -> {io, ""} end, &null_chunk/1, fn {io, _} -> File.close(io) end)

      bounded_entries(
        stream |> Stream.map(&String.trim_leading(&1, "./")),
        cwd,
        Keyword.get(opts, :limit, 500),
        Keyword.get(opts, :max_bytes, 16_000),
        "No files found matching pattern",
        result.output_path
      )
    end
  end

  @doc "Search a regex or literal, with bounded match counts, lines and optional context."
  def grep(pattern, opts \\ []) do
    path = Keyword.get(opts, :path, ".")
    cwd = if File.dir?(path), do: path, else: Path.dirname(Path.expand(path))
    target = if File.dir?(path), do: ".", else: Path.basename(path)
    args = ["--json", "--hidden", "--no-require-git", "--color", "never", "-g", "!.git"]
    args = args ++ if(Keyword.get(opts, :literal, false), do: ["--fixed-strings"], else: [])
    args = args ++ if(Keyword.get(opts, :ignore_case, false), do: ["--ignore-case"], else: [])

    args =
      args ++
        if(Keyword.has_key?(opts, :glob),
          do: ["--type-add", "seedling:" <> Keyword.fetch!(opts, :glob), "-t", "seedling"],
          else: []
        )

    args = args ++ ["--context", to_string(Keyword.get(opts, :context, 0)), "--", pattern, target]

    with :ok <- search_options(opts, 100),
         {:ok, result} <- rg(args, cwd, opts) do
      search_lines(result.output_path, opts)
    end
  end

  defp search_lines(path, opts) do
    limit = Keyword.get(opts, :limit, 100)
    cap = Keyword.get(opts, :max_bytes, 16_000)
    chars = Keyword.get(opts, :max_line_chars, 500)
    state = %{entries: [], matches: 0, bytes: 0, truncated: false, lines_truncated: false}

    result =
      Enum.reduce_while(File.stream!(path), state, fn line, state ->
        case Jason.decode(line) do
          {:ok, %{"type" => type, "data" => data}} when type in ["match", "context"] ->
            text = data["lines"]["text"] || Base.decode64!(data["lines"]["bytes"])
            file = data["path"]["text"] || Base.decode64!(data["path"]["bytes"])

            text =
              text |> Shell.scrub() |> String.trim_trailing("\n") |> String.trim_trailing("\r")

            cut_line = String.length(text) > chars
            text = String.slice(text, 0, chars)
            sep = if type == "match", do: ":", else: "-"

            display =
              "#{String.trim_leading(file, "./")}#{sep}#{data["line_number"]}#{sep} #{text}"

            if (type == "match" and state.matches >= limit) or
                 state.bytes + byte_size(display) + 1 > cap do
              {:halt, %{state | truncated: true}}
            else
              entry = %{
                path: String.trim_leading(file, "./"),
                line: data["line_number"],
                text: text,
                kind: String.to_existing_atom(type),
                truncated: cut_line
              }

              {:cont,
               %{
                 state
                 | entries: [{entry, display} | state.entries],
                   matches: state.matches + if(type == "match", do: 1, else: 0),
                   bytes: state.bytes + byte_size(display) + 1,
                   lines_truncated: state.lines_truncated or cut_line
               }}
            end

          _ ->
            {:cont, state}
        end
      end)

    entries = Enum.reverse(result.entries)

    notice =
      [
        if(result.truncated,
          do:
            "Search limit reached (#{limit} matches/#{cap} bytes). Increase limit/max_bytes or refine pattern."
        ),
        if(result.lines_truncated,
          do: "Some lines truncated to #{chars} characters. Use read/2 to see full lines."
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    {:ok,
     %{
       text:
         if(entries == [],
           do: "No matches found",
           else: Enum.map_join(entries, "\n", &elem(&1, 1))
         ),
       entries: Enum.map(entries, &elem(&1, 0)),
       matches: result.matches,
       truncated: result.truncated,
       lines_truncated: result.lines_truncated,
       notice: if(notice == "", do: nil, else: notice),
       output_path: path
     }}
  end

  defp search_options(opts, default) do
    if positive?(Keyword.get(opts, :limit, default)) and
         positive?(Keyword.get(opts, :max_bytes, 16_000)) and
         positive?(Keyword.get(opts, :max_line_chars, 500)) and
         is_integer(Keyword.get(opts, :context, 0)) and Keyword.get(opts, :context, 0) >= 0,
       do: :ok,
       else:
         error(
           :invalid_options,
           "limit, max_bytes, max_line_chars must be positive integers; context must be nonnegative."
         )
  end

  defp rg(args, cwd, opts) do
    case System.find_executable("rg") do
      nil ->
        error(
          :missing_dependency,
          "Install ripgrep to use find/2 and grep/2 (apt-get install ripgrep)."
        )

      executable ->
        command = Enum.map_join([executable | args], " ", &quote_arg/1)

        with {:ok, result} <-
               Shell.sh(command,
                 cwd: cwd,
                 timeout: Keyword.get(opts, :timeout, 30_000),
                 spool_dir:
                   Keyword.get(opts, :spool_dir, Path.join(System.tmp_dir!(), "seedling-shell"))
               ) do
          if result.status == :exited and result.exit_code in [0, 1],
            do: {:ok, result},
            else:
              error(
                :search_failed,
                "Search failed (#{result.status}, exit #{inspect(result.exit_code)}): #{result.output}. Check pattern/path; full diagnostics: #{result.output_path}"
              )
        end
    end
  end

  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp null_chunk({io, pending}) do
    case IO.binread(io, 65_536) do
      :eof ->
        {:halt, {io, pending}}

      data when is_binary(data) ->
        parts = :binary.split(pending <> data, <<0>>, [:global])
        {Enum.drop(parts, -1), {io, List.last(parts)}}
    end
  end

  defp bounded_entries(entries, path, limit, cap, empty, output_path \\ nil) do
    if positive?(limit) and positive?(cap) do
      {kept, _bytes, cut} =
        Enum.reduce_while(entries, {[], 0, false}, fn entry, {kept, bytes, _} ->
          if length(kept) >= limit or bytes + byte_size(entry) + 1 > cap,
            do: {:halt, {kept, bytes, true}},
            else: {:cont, {[entry | kept], bytes + byte_size(entry) + 1, false}}
        end)

      kept = Enum.reverse(kept)

      {:ok,
       %{
         path: path,
         entries: kept,
         text: if(kept == [], do: empty, else: Enum.join(kept, "\n")),
         truncated: cut,
         notice:
           if(cut,
             do:
               "Listing limit reached (#{limit} entries/#{cap} bytes). Increase limit/max_bytes or narrow the glob.",
             else: nil
           ),
         output_path: output_path
       }}
    else
      error(:invalid_options, "limit and max_bytes must be positive integers.")
    end
  end

  defp writable(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        error(:symlink, "#{path} is a symlink; edit its resolved target explicitly.")

      {:ok, %{type: :directory}} ->
        error(:eisdir, "#{path} is a directory; choose a file path.")

      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        file_error(:write, path, reason)
    end
  end

  defp atomic_write(path, content) do
    temp = path <> ".seedling-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    mode =
      case File.stat(path) do
        {:ok, stat} -> Bitwise.band(stat.mode, 0o777)
        _ -> nil
      end

    result =
      with :ok <- File.write(temp, content, [:exclusive]),
           :ok <- if(mode, do: File.chmod(temp, mode), else: :ok),
           do: File.rename(temp, path)

    File.rm(temp)
    result
  end

  defp positive?(n), do: is_integer(n) and n > 0

  defp file_error(action, path, reason),
    do:
      error(
        reason,
        "Cannot #{action} #{path}: #{:file.format_error(reason)}. Check the path, file type and permissions."
      )

  @doc false
  def error(reason, message), do: {:error, %{reason: reason, message: message}}
end
