defmodule Seedling.Tools do
  @moduledoc """
  Bounded file and shell helpers for eval. See `docs/tools.md` for options/examples.

  File/search operations return `{:ok, result}` or `{:error, %{kind: ..., message: ...}}`;
  `write/2` returns `:ok`. `sh/2` returns a result map (including nonzero exits), or
  an error tuple if it cannot start. Results have compact `text` and truncation metadata.
  Defaults: 200 lines / 16,000 bytes; listings 500 entries, find 1,000 paths,
  grep 100 matches / 500 characters per line. Every cut includes a continuation hint.
  Shell output always spills to a uniquely named file; caller owns its retention.
  Search requires ripgrep and fd (Debian: `apt-get install ripgrep fd-find`).
  """
  @bytes 16_000
  @lines 200

  def read(path, opts \\ []) do
    protect(fn ->
      offset = option!(opts, :offset, 1)
      limit = option!(opts, :limit, @lines)
      cap = option!(opts, :max_bytes, @bytes)

      # Scan once for an honest total, keeping only complete requested lines.
      {total, kept, bytes, blocked, oversized} =
        binary_lines(path)
        |> Enum.reduce({0, [], 0, false, nil}, fn line, {n, kept, bytes, blocked, big} ->
          n = n + 1

          cond do
            n < offset or blocked ->
              {n, kept, bytes, blocked, big}

            length(kept) >= limit ->
              {n, kept, bytes, true, big}

            bytes + byte_size(line) > cap ->
              {n, kept, bytes, true, if(kept == [], do: {n, byte_size(line)}, else: big)}

            true ->
              {n, [line | kept], bytes + byte_size(line), false, big}
          end
        end)

      cond do
        offset > max(total, 1) ->
          error(
            :offset,
            "Offset #{offset} is past EOF (#{total} lines). Use offset <= #{max(total, 1)}.",
            %{total_lines: total}
          )

        oversized != nil ->
          {line, size} = oversized

          error(
            :line_too_long,
            "Line #{line} is #{size} bytes, exceeding max_bytes=#{cap}; increase max_bytes to at least #{size}.",
            %{line: line, line_bytes: size, total_lines: total}
          )

        true ->
          count = length(kept)
          next = offset + count
          cut = blocked or next <= total

          {:ok,
           %{
             text: kept |> Enum.reverse() |> IO.iodata_to_binary(),
             total_lines: total,
             start_line: offset,
             end_line: if(count == 0, do: 0, else: next - 1),
             next_offset: next,
             truncated: cut,
             bytes: bytes,
             notice:
               if(cut,
                 do:
                   "Showing lines #{offset}-#{next - 1} of #{total}. Use offset=#{next} to continue (limit=#{limit}, max_bytes=#{cap}).",
                 else: nil
               )
           }}
      end
    end)
  end

  def write(path, text) do
    protect(fn ->
      with :ok <- file_result(File.mkdir_p(Path.dirname(path)), Path.dirname(path)),
           :ok <- file_result(File.write(path, text), path),
           do: :ok
    end)
  end

  def edit(path, old, new), do: edit(path, [{old, new}])

  @doc "Validate disjoint {old, new} pairs against the original, then write once."
  def edit(path, replacements) do
    protect(fn ->
      with {:ok, original} <- file_result(File.read(path), path),
           :ok <- editable_text(original),
           {:ok, spans} <- edit_spans(original, replacements),
           :ok <- disjoint(spans) do
        updated =
          spans
          |> Enum.sort_by(& &1.start, :desc)
          |> Enum.reduce(original, fn span, text ->
            binary_part(text, 0, span.start) <>
              span.new <>
              binary_part(text, span.start + span.size, byte_size(text) - span.start - span.size)
          end)

        if updated == original do
          error(:no_change, "Replacements change nothing. Supply different new text.")
        else
          diff = short_diff(original, updated)

          with :ok <- File.write(path, updated) do
            {:ok,
             %{
               path: path,
               replacements: length(spans),
               tolerant_matches: Enum.count(spans, & &1.tolerant),
               diff: diff
             }}
          end
        end
      end
    end)
  end

  defp editable_text(text) do
    if String.valid?(text),
      do: :ok,
      else: error(:invalid_encoding, "edit requires UTF-8 text. Use write for binary files.")
  end

  defp normalize_eol(original, text) do
    eol = if String.contains?(original, "\r\n"), do: "\r\n", else: "\n"
    text |> String.replace("\r\n", "\n") |> String.replace("\n", eol)
  end

  defp edit_spans(_, []), do: error(:invalid_edit, "Supply at least one {old, new} replacement.")

  defp edit_spans(original, pairs) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      {old, new}, {:ok, spans} when is_binary(old) and is_binary(new) and old != "" ->
        new = normalize_eol(original, new)

        case if(String.valid?(old) and String.valid?(new),
               do: match_span(original, old),
               else:
                 error(
                   :invalid_encoding,
                   "edit requires UTF-8 old and new text. Use write for binary rewrites."
                 )
             ) do
          {:ok, span} ->
            if binary_part(original, span.start, span.size) == new do
              {:halt,
               error(:no_change, "A replacement changes nothing. Supply different new text.")}
            else
              {:cont, {:ok, [Map.put(span, :new, new) | spans]}}
            end

          err ->
            {:halt, err}
        end

      _, _ ->
        {:halt, error(:invalid_edit, "Each replacement must be {nonempty old text, new text}.")}
    end)
  end

  defp edit_spans(_, _), do: error(:invalid_edit, "Supply a list of {old, new} replacements.")

  defp match_span(original, old) do
    case occurrences(original, old) do
      [{start, size}] ->
        {:ok, %{start: start, size: size, tolerant: false}}

      [] ->
        {normalized, mapping} = normalize_with_mapping(original)
        {needle, _} = normalize_with_mapping(old)
        matches = if needle == "", do: [], else: occurrences(normalized, needle)

        case matches do
          [{start, size}] ->
            first = Map.fetch!(mapping, start)
            last = Map.fetch!(mapping, start + size - 1)
            {:ok, %{start: elem(first, 0), size: elem(last, 1) - elem(first, 0), tolerant: true}}

          [] ->
            error(
              :not_found,
              "Old text not found. It must match exactly, including whitespace and newlines (limited tolerance: trailing whitespace, curly quotes, Unicode dashes, CRLF)."
            )

          many ->
            ambiguous(length(many))
        end

      many ->
        ambiguous(length(many))
    end
  end

  defp occurrences(text, needle), do: occurrences(text, needle, 0, [])

  defp occurrences(text, needle, pos, found) when pos <= byte_size(text) - byte_size(needle) do
    case :binary.match(text, needle, scope: {pos, byte_size(text) - pos}) do
      :nomatch -> Enum.reverse(found)
      {start, size} -> occurrences(text, needle, start + 1, [{start, size} | found])
    end
  end

  defp occurrences(_, _, _, found), do: Enum.reverse(found)

  defp ambiguous(n),
    do:
      error(:ambiguous, "Old text found #{n} times. Add context to make it unique.", %{matches: n})

  # Map normalized byte positions to original spans, so tolerant replacements never
  # rewrite untouched text or lose original whitespace outside the matched span.
  defp normalize_with_mapping(text) do
    unless String.valid?(text), do: raise(ArgumentError, "edit requires UTF-8 text")

    trailing =
      Regex.scan(~r/[\t ]+(?=\r?$)/m, text, return: :index) |> Map.new(fn [{s, n}] -> {s, n} end)

    normalize_chars(text, 0, 0, [], %{}, trailing)
  end

  defp normalize_chars("", _, _, parts, map, _),
    do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), map}

  defp normalize_chars(text, pos, norm, parts, map, trailing) do
    case Map.get(trailing, pos) do
      n when is_integer(n) ->
        normalize_chars(
          binary_part(text, n, byte_size(text) - n),
          pos + n,
          norm,
          parts,
          map,
          trailing
        )

      nil ->
        {char, rest, n} =
          case text do
            <<"\r\n", rest::binary>> -> {"\n", rest, 2}
            <<cp::utf8, rest::binary>> -> {<<cp::utf8>>, rest, byte_size(<<cp::utf8>>)}
          end

        char =
          case char do
            c when c in ["‘", "’", "‚", "‛"] -> "'"
            c when c in ["“", "”", "„", "‟"] -> "\""
            c when c in ["‐", "‑", "‒", "–", "—", "−"] -> "-"
            c -> c
          end

        map =
          Enum.reduce(norm..(norm + byte_size(char) - 1), map, &Map.put(&2, &1, {pos, pos + n}))

        normalize_chars(rest, pos + n, norm + byte_size(char), [char | parts], map, trailing)
    end
  end

  defp disjoint(spans) do
    spans
    |> Enum.sort_by(& &1.start)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn [a, b], _ ->
      if a.start + a.size > b.start,
        do:
          {:halt,
           error(
             :overlap,
             "Replacements overlap in the original file. Use disjoint old text or combine them."
           )},
        else: {:cont, :ok}
    end)
  end

  defp short_diff(old, new) do
    {lines, _, _} =
      List.myers_difference(String.split(old, "\n"), String.split(new, "\n"))
      |> Enum.reduce({[], 1, 1}, fn
        {:eq, xs}, {out, a, b} ->
          {out, a + length(xs), b + length(xs)}

        {:del, xs}, {out, a, b} ->
          {out ++ Enum.map(Enum.with_index(xs, a), fn {s, n} -> "-#{n}| #{s}" end),
           a + length(xs), b}

        {:ins, xs}, {out, a, b} ->
          {out ++ Enum.map(Enum.with_index(xs, b), fn {s, n} -> "+#{n}| #{s}" end), a,
           b + length(xs)}
      end)

    {text, cut} = head_lines(lines, 80, 8_000)
    text <> if(cut, do: "\n[Diff truncated; use read(path) for full contents.]", else: "")
  end

  def ls(path, opts \\ []) do
    protect(fn ->
      limit = option!(opts, :limit, 500)
      cap = option!(opts, :max_bytes, @bytes)

      with {:ok, names} <- file_result(File.ls(path), path) do
        entries =
          names
          |> Enum.sort()
          |> Enum.map(fn name ->
            name <> if(File.dir?(Path.join(path, name)), do: "/", else: "")
          end)

        listing(entries, limit, cap, "entries", "(empty directory)")
      end
    end)
  end

  def find(glob, opts \\ []) do
    protect(fn ->
      {cwd, glob} = find_location(glob, Keyword.get(opts, :cwd, "/app"))
      limit = option!(opts, :limit, 1_000)
      cap = option!(opts, :max_bytes, @bytes)
      fd = System.find_executable("fd") || System.find_executable("fdfind")

      if fd == nil do
        error(
          :missing_dependency,
          "find requires fd. Install fd-find (Debian) or fd, then retry."
        )
      else
        # fd's glob matching is relative to cwd; include dotfiles but honor ignore files.
        args = [
          "--hidden",
          "--no-require-git",
          "--exclude",
          ".git",
          "--glob",
          "--color",
          "never",
          "--print0",
          "--",
          glob,
          "."
        ]

        case run_capture(fd, args, cwd, opts) do
          %{status: 0, full_output: output} ->
            entries =
              File.read!(output)
              |> :binary.split(<<0>>, [:global])
              |> Enum.reject(&(&1 == ""))
              |> Enum.map(&String.replace_prefix(&1, "./", ""))
              |> Enum.sort()

            with {:ok, result} <-
                   listing(entries, limit, cap, "results", "No files found matching pattern"),
                 do: {:ok, Map.put(result, :full_output, output)}

          %{output: text} ->
            error(:find, "find failed: #{text}. Check glob and cwd.")

          err ->
            err
        end
      end
    end)
  end

  defp find_location(glob, cwd) do
    if Path.type(glob) == :absolute do
      parts = Path.split(glob)

      {prefix, pattern} =
        Enum.split_while(parts, fn part -> not String.contains?(part, ["*", "?", "["]) end)

      if pattern == [],
        do: {Path.dirname(glob), Path.basename(glob)},
        else: {Path.join(prefix), Path.join(pattern)}
    else
      {cwd, glob}
    end
  end

  def grep(pattern, path \\ "/app", opts \\ []) do
    protect(fn ->
      limit = option!(opts, :limit, 100)
      cap = option!(opts, :max_bytes, @bytes)
      line_cap = option!(opts, :line_length, 500)
      context = Keyword.get(opts, :context, 0)

      unless is_integer(context) and context >= 0,
        do: raise(ArgumentError, "context must be a nonnegative integer")

      rg = System.find_executable("rg")

      if rg == nil do
        error(:missing_dependency, "grep requires ripgrep. Install ripgrep, then retry.")
      else
        cwd = if File.dir?(path), do: Path.expand(path), else: Path.dirname(Path.expand(path))
        target = if File.dir?(path), do: ".", else: Path.basename(path)

        args =
          [
            "--json",
            "--hidden",
            "--no-require-git",
            "--glob",
            "!.git/**",
            "--color",
            "never",
            "--context",
            to_string(context)
          ] ++
            if(Keyword.get(opts, :literal, false), do: ["--fixed-strings"], else: []) ++
            if(Keyword.get(opts, :ignore_case, false), do: ["--ignore-case"], else: []) ++
            ["--", pattern, target]

        allowed =
          case Keyword.get(opts, :glob) do
            nil ->
              nil

            glob ->
              glob = if String.contains?(glob, "/"), do: glob, else: "**/" <> glob

              Path.wildcard(Path.join(cwd, glob), match_dot: true)
              |> Enum.map(&Path.relative_to(&1, cwd))
              |> MapSet.new()
          end

        case run_capture(rg, args, cwd, opts) do
          %{status: 1, full_output: output} ->
            {:ok,
             %{
               text: "No matches found",
               matches: 0,
               total_matches: 0,
               truncated: false,
               notice: nil,
               full_output: output
             }}

          %{status: 0, full_output: output} ->
            grep_result(output, limit, cap, line_cap, allowed)

          %{output: text} ->
            error(:grep, "grep failed: #{text}. Check pattern and path.")

          err ->
            err
        end
      end
    end)
  end

  defp grep_result(path, limit, cap, line_cap, allowed) do
    {rows, matches, cut, shortened, _bytes, shown} =
      binary_lines(path)
      |> Enum.reduce({[], 0, false, false, 0, 0}, fn json,
                                                     {rows, matches, cut, shortened, bytes, shown} ->
        event = Jason.decode!(json)

        file =
          String.replace_prefix(
            get_in(event, ["data", "path", "text"]) || "[binary path]",
            "./",
            ""
          )

        if event["type"] in ["match", "context"] and
             (allowed == nil or MapSet.member?(allowed, file)) do
          data = event["data"]
          matching = event["type"] == "match"
          matches = matches + if(matching, do: 1, else: 0)
          raw = data["lines"]["text"] || "[binary line; use read]"

          line =
            raw
            |> String.replace_invalid()
            |> String.trim_trailing("\n")
            |> String.trim_trailing("\r")

          short = String.length(line) > line_cap
          line = String.slice(line, 0, line_cap) <> if(short, do: "…", else: "")
          file = String.replace_prefix(data["path"]["text"] || "[binary path]", "./", "")
          separator = if matching, do: ":", else: "-"
          row = "#{file}#{separator}#{data["line_number"]}#{separator} #{line}"

          if cut or matches > limit or bytes + byte_size(row) + 1 > cap do
            {rows, matches, true, shortened or short, bytes, shown}
          else
            {[row | rows], matches, false, shortened or short, bytes + byte_size(row) + 1,
             shown + if(matching, do: 1, else: 0)}
          end
        else
          {rows, matches, cut, shortened, bytes, shown}
        end
      end)

    notice =
      Enum.reject(
        [
          if(cut,
            do:
              "Results capped at limit=#{limit} matches or max_bytes=#{cap}. Use limit=#{limit * 2}, max_bytes=#{cap * 2}, or refine pattern."
          ),
          if(shortened,
            do:
              "Some lines truncated to #{line_cap} characters. Use read(path) to see full lines."
          )
        ],
        &is_nil/1
      )
      |> Enum.join(" ")

    text =
      if matches == 0, do: "No matches found", else: rows |> Enum.reverse() |> Enum.join("\n")

    {:ok,
     %{
       text: append_notice(text, notice),
       full_output: path,
       matches: shown,
       total_matches: matches,
       truncated: cut or shortened,
       notice: empty_nil(notice)
     }}
  end

  defp listing(entries, limit, cap, unit, empty) do
    {text, cut} = head_lines(entries, limit, cap)

    notice =
      if cut,
        do:
          "#{limit} #{unit} or max_bytes=#{cap} limit reached. Use limit=#{limit * 2}, max_bytes=#{cap * 2}, or narrow the path/glob.",
        else: nil

    {:ok,
     %{
       text: append_notice(if(entries == [], do: empty, else: text), notice),
       entries: text |> String.split("\n", trim: true),
       total_entries: length(entries),
       truncated: cut,
       notice: notice
     }}
  end

  def quote_arg(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  def sh(cmd, opts \\ []) do
    protect(fn ->
      timeout = Keyword.get(opts, :timeout, 60_000)

      unless timeout == :infinity or (is_integer(timeout) and timeout > 0),
        do: raise(ArgumentError, "timeout must be positive milliseconds or :infinity")

      option!(opts, :limit, @lines)
      option!(opts, :max_bytes, @bytes)
      cwd = Keyword.get(opts, :cwd, "/app") |> Path.expand()
      unless File.dir?(cwd), do: raise(ArgumentError, "cwd #{cwd} is not an existing directory")

      dir =
        Keyword.get(opts, :output_dir, Path.join(System.tmp_dir!(), "seedling-tools"))
        |> Path.expand()

      :ok = File.mkdir_p(dir)

      path =
        Path.join(
          dir,
          "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.log"
        )

      start = System.monotonic_time(:millisecond)
      marker = path <> ".exit"

      term_marker = path <> ".term"
      # A plain wrapper can die on TERM while resistant grandchildren survive,
      # causing GNU timeout to cancel its KILL timer. Keep the tracked shell
      # alive through the grace period even if the direct child exits; escalation
      # must still reach any resistant grandchildren in the same group.
      trap = "printf term > " <> quote_arg(term_marker) <> "; sleep 2; wait \"$child\""

      script =
        "trap " <>
          quote_arg(trap) <>
          " TERM; (" <>
          cmd <>
          ") > " <>
          quote_arg(path) <>
          " 2>&1 & child=$!; wait \"$child\"; code=$?; printf '%s' \"$code\" > " <>
          quote_arg(marker) <> "; exit \"$code\""

      {output, status} =
        if timeout == :infinity do
          System.cmd("sh", ["-c", script],
            cd: cwd,
            env: Keyword.get(opts, :env, []),
            stderr_to_stdout: true
          )
        else
          System.cmd("timeout", ["--kill-after=1s", "#{timeout / 1000}s", "sh", "-c", script],
            cd: cwd,
            env: Keyword.get(opts, :env, []),
            stderr_to_stdout: true
          )
        end

      if not File.exists?(path), do: File.write!(path, output)

      timed_out =
        timeout != :infinity and status in [124, 137] and
          (File.exists?(term_marker) or not File.exists?(marker))

      File.rm(term_marker)
      File.rm(marker)
      tail = tail(path, opts)

      Map.merge(tail, %{
        status: status,
        timed_out: timed_out,
        full_output: path,
        elapsed_ms: System.monotonic_time(:millisecond) - start
      })
    end)
  end

  @doc "Read bounded shell-style tail without loading the full file; useful for background logs."
  def tail(path, opts \\ []) do
    protect(fn ->
      cap = option!(opts, :max_bytes, @bytes)
      limit = option!(opts, :limit, @lines)

      {total_lines, total_bytes, ending} =
        File.stream!(path, 64_000)
        |> Enum.reduce({0, 0, ""}, fn chunk, {n, bytes, _} ->
          {n + length(:binary.matches(chunk, "\n")), bytes + byte_size(chunk),
           binary_part(chunk, byte_size(chunk) - 1, 1)}
        end)

      total_lines = total_lines + if(total_bytes > 0 and ending != "\n", do: 1, else: 0)
      {:ok, file} = File.open(path, [:read, :binary])

      text =
        try do
          {:ok, _} = :file.position(file, max(total_bytes - cap, 0))

          case IO.binread(file, cap) do
            :eof -> ""
            bytes when is_binary(bytes) -> bytes
          end
        after
          File.close(file)
        end

      # Drop incomplete UTF-8 prefix, never split the retained final codepoint.
      text = valid_tail(text)
      lines = :binary.split(text, "\n", [:global])
      lines = if ending == "\n", do: Enum.drop(lines, -1), else: lines
      lines = if total_bytes == 0, do: [], else: Enum.take(lines, -limit)
      output = Enum.join(lines, "\n") <> if(ending == "\n" and lines != [], do: "\n", else: "")
      cut = total_bytes > cap or total_lines > limit
      start_line = max(total_lines - length(lines) + 1, 1)

      notice =
        if cut,
          do:
            "Showing tail lines #{start_line}-#{total_lines} of #{total_lines}, up to #{cap} bytes (first line may be partial). Full output: #{path}. Use read(path, offset: #{start_line}) or tail(path, limit: #{limit * 2}, max_bytes: #{cap * 2}).",
          else: nil

      %{
        output: output,
        truncated: cut,
        notice: notice,
        total_lines: total_lines,
        total_bytes: total_bytes,
        start_line: start_line,
        end_line: total_lines
      }
    end)
  end

  # IO/File readline normalizes CRLF. Split raw chunks instead to preserve bytes.
  defp binary_lines(path) do
    Stream.concat(File.stream!(path, 64_000), [:eof])
    |> Stream.transform("", fn
      :eof, pending ->
        {if(pending == "", do: [], else: [pending]), ""}

      chunk, pending ->
        parts = :binary.split(pending <> chunk, "\n", [:global])
        {parts |> Enum.drop(-1) |> Enum.map(&(&1 <> "\n")), List.last(parts)}
    end)
  end

  defp valid_tail(text) do
    cond do
      String.valid?(text) ->
        text

      text == "" ->
        ""

      true ->
        # Invalid output is rendered safely. ASCII '?' doesn't inflate the byte cap.
        text |> String.replace_invalid("?")
    end
  end

  defp run_capture(executable, args, cwd, opts) do
    sh(Enum.map_join([executable | args], " ", &quote_arg/1), Keyword.put(opts, :cwd, cwd))
  end

  defp head_lines(lines, limit, cap) do
    {kept, _, cut} =
      Enum.reduce_while(lines, {[], 0, false}, fn line, {kept, bytes, _} ->
        size = byte_size(line) + if(kept == [], do: 0, else: 1)

        if length(kept) >= limit or bytes + size > cap,
          do: {:halt, {kept, bytes, true}},
          else: {:cont, {[line | kept], bytes + size, false}}
      end)

    {kept |> Enum.reverse() |> Enum.join("\n"), cut}
  end

  defp option!(opts, key, default) do
    n = Keyword.get(opts, key, default)
    unless is_integer(n) and n > 0, do: raise(ArgumentError, "#{key} must be a positive integer")
    n
  end

  defp append_notice(text, nil), do: text
  defp append_notice(text, ""), do: text
  defp append_notice(text, notice), do: text <> "\n[" <> notice <> "]"
  defp empty_nil(""), do: nil
  defp empty_nil(s), do: s

  defp error(kind, message, extra \\ %{}),
    do: {:error, Map.merge(%{kind: kind, message: message}, extra)}

  defp file_result({:error, reason}, path) do
    error(
      reason,
      "#{path}: #{:file.format_error(reason)}. Check that this path exists, has the expected type and is accessible."
    )
  end

  defp file_result(result, _), do: result

  defp protect(fun) do
    case fun.() do
      {:error, reason} when is_atom(reason) ->
        error(reason, "#{:file.format_error(reason)}. Check the path, its type and permissions.")

      result ->
        result
    end
  rescue
    e ->
      error(
        :operation_failed,
        Exception.message(e) <> ". Check options, path, or required executable."
      )
  end
end
