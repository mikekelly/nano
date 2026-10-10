defmodule Nano.Tools do
  @moduledoc """
  Bounded local tools returning `{:ok, map}` or `{:error, explanation}`.
  Read and edit preserve original bytes. Read pages use one-based line offsets, listings/search zero-based result offsets.
  Defaults: 200 lines/entries, 16000 bytes (grep 100 matches, 500 chars/line).
  Every cut includes a continuation. find/grep include hidden files but respect ignore
  rules via ripgrep (required; installed by Dockerfile). Use `include_ignored: true`
  to bypass ignore files, `glob:` to narrow grep. find returns files only. Binary
  (NUL or invalid UTF8) files are skipped and counted by grep; lines exceeding
  `max_line_bytes` (1MB default) return an error. Regexes use Elixir semantics. Shell saves complete output and returns its tail.
  Examples: `read("mix.exs")`, `grep("def", path: "lib", glob: "**/*.ex")`,
  `sh("mix test", cwd: "/tmp/my-worktree")`. Long jobs: `Nano.Background.start/2`.

  read/tail/list/find/grep accept `limit:` and `max_bytes:`; explicit bounds are
  positive integers. read rejects offsets past EOF, but reading an empty file at
  offset 1 returns empty text. Search/list continuation uses `next_offset`, and
  an entry too large for an empty page returns an error instead of a stuck cursor.
  grep returns `lines_truncated`, `binary_files_skipped` (visited files only) and
  `notices`; `max_line_chars:` changes its per-match display bound. Explicit file
  searches bypass ignore rules. find uses `cwd:`, grep uses `path:`. Filename
  enumeration is materialized and sorted, with `enumeration_timeout:` (5000ms
  default) and a complete output spool; errors/timeouts are explicit values. Filename line/match buffering is bounded, even
  for large offsets. `tail` replaces malformed UTF8 with U+FFFD and reports
  `encoding_replaced`, keeping valid UTF8 text inside max_bytes. Output files
  preserve original bytes. No automatic spool cleanup or disk quota is applied.
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
          next <= offset and offset > 1 ->
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

      raw_text = text
      text = safe_utf8(text)
      replaced = text != raw_text
      expanded = byte_size(text) > cap

      text =
        if expanded, do: valid_suffix(binary_part(text, byte_size(text) - cap, cap)), else: text

      lines = String.split(text, "\n")

      {:ok,
       %{
         text: Enum.take(lines, -limit) |> Enum.join("\n"),
         bytes: size,
         cut: size > cap or length(lines) > limit or expanded,
         encoding_replaced: replaced,
         path: path,
         continuation: "read(path, offset: 1) for full paged output"
       }}
    end)
  end

  defp safe_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      text when is_binary(text) -> text
      {:error, good, rest} -> good <> "�" <> safe_utf8(binary_part(rest, 1, byte_size(rest) - 1))
      {:incomplete, good, _rest} -> good <> "�"
    end
  end

  defp valid_suffix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_suffix(binary_part(binary, 1, byte_size(binary) - 1))
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
      if not File.dir?(cwd), do: raise(ArgumentError, "cwd is not a directory: #{cwd}")

      searchable_files(cwd, glob, opts)
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

      base = if File.dir?(root), do: root, else: Path.dirname(root)

      files =
        if File.regular?(root),
          do: [root],
          else: searchable_files(root, Keyword.get(opts, :glob, "**/*"), opts)

      offset = nonnegative(opts, :offset, 0)
      limit = positive(opts, :limit, 100)
      line_cap = positive(opts, :max_line_bytes, 1_000_000)
      max_chars = positive(opts, :max_line_chars, 500)
      # The accumulator tracks only visited files and the requested page plus one match.
      {matches, skipped, _} =
        Enum.reduce_while(files, {[], 0, 0}, fn file, {matches, skipped, count} ->
          remaining = limit + 1 - length(matches)

          case grep_file(
                 file,
                 regex,
                 line_cap,
                 max_chars,
                 remaining,
                 base,
                 max(0, offset - count)
               ) do
            :binary ->
              {:cont, {matches, skipped + 1, count}}

            {found, scanned} ->
              count = count + scanned
              result = {matches ++ found, skipped, count}

              if length(matches) + length(found) >= limit + 1,
                do: {:halt, result},
                else: {:cont, result}
          end
        end)

      {:ok, r} =
        page(Enum.map(matches, &elem(&1, 0)), Keyword.merge(opts, offset: 0, limit: limit))

      truncated = matches |> Enum.take(length(r.entries)) |> Enum.any?(&elem(&1, 1))

      continuation =
        if r.cut,
          do: "grep with offset: #{offset + length(r.entries)} or increase max_bytes",
          else: nil

      notices =
        if truncated,
          do: [
            "Some matching lines truncated to #{max_chars} characters; use read for full lines"
          ],
          else: []

      notices =
        if skipped > 0,
          do: notices ++ ["Skipped #{skipped} binary/invalid UTF8 files"],
          else: notices

      {:ok,
       Map.merge(r, %{
         next_offset: if(r.cut, do: offset + length(r.entries)),
         continuation: continuation,
         lines_truncated: truncated,
         binary_files_skipped: skipped,
         notices: notices
       })}
    end)
  end

  defp searchable_files(cwd, glob, opts) do
    rg =
      System.find_executable("rg") ||
        raise "ripgrep is required for ignore-aware search; install package ripgrep"

    args = [
      "--files",
      "--hidden",
      "--no-require-git",
      "--null",
      "--glob",
      "!**/.git/**"
    ]

    args = if Keyword.get(opts, :include_ignored, false), do: args ++ ["--no-ignore"], else: args
    allowed = Path.wildcard(Path.join(cwd, glob), match_dot: true) |> MapSet.new()
    # Positive rg globs override ignores, so glob filtering happens after enumeration.
    # Enumeration uses the same timeout/spool machinery as shell; stdout is parsed
    # from the complete spool, not from its bounded tail. Diagnostics cannot be paths.
    timeout = positive(opts, :enumeration_timeout, 5000)
    command = Enum.map_join([rg | args], " ", &shell_quote/1) <> " 2>/dev/null"

    case Nano.Background.run(command, cwd: cwd, timeout: timeout, max_bytes: 1000, limit: 10) do
      {:ok, %{status: :completed, exit_code: code, output_path: output}} when code in [0, 1] ->
        File.read!(output)
        |> :binary.split(<<0>>, [:global])
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Path.expand(&1, cwd))
        |> Enum.filter(&MapSet.member?(allowed, &1))
        |> Enum.sort()

      {:ok, %{status: :timed_out}} ->
        raise "ripgrep enumeration timed out after #{timeout}ms; narrow path or increase enumeration_timeout"

      {:ok, result} ->
        raise "ripgrep enumeration failed (#{result.status}, exit #{inspect(result[:exit_code])}); check path, permissions and glob"

      {:error, reason} ->
        raise "cannot run ripgrep enumeration: #{reason}"
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp grep_file(file, regex, cap, max_chars, remaining, base, skip) do
    File.open!(file, [:read, :binary, :raw], fn io ->
      # Read byte-bounded lines; never feed malformed text to Unicode regex/string code.
      lines =
        Stream.repeatedly(fn -> bounded_line(io, cap) end)
        |> Stream.take_while(&(&1 != :eof))
        |> Stream.map(fn {:ok, line} -> line end)

      lines
      |> Stream.with_index(1)
      |> Enum.reduce_while({[], 0}, fn {line, n}, {found, scanned} ->
        cond do
          :binary.match(line, <<0>>) != :nomatch or not String.valid?(line) ->
            {:halt, :binary}

          Regex.match?(regex, line) ->
            line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
            shortened = String.slice(line, 0, max_chars)

            entry =
              {"#{Path.relative_to(file, base)}:#{n}: " <> shortened,
               byte_size(shortened) < byte_size(line)}

            scanned = scanned + 1
            found = if scanned > skip, do: found ++ [entry], else: found
            result = {found, scanned}
            if length(found) >= remaining, do: {:halt, result}, else: {:cont, result}

          true ->
            {:cont, {found, scanned}}
        end
      end)
    end)
  end

  def sh(command, opts \\ []), do: Nano.Background.run(command, opts)

  defp page(entries, opts) do
    offset = nonnegative(opts, :offset, 0)

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

    if cut and kept == [],
      do: raise(ArgumentError, "entry exceeds max_bytes; increase max_bytes to make progress")

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

  defp nonnegative(opts, key, default) do
    n = Keyword.get(opts, key, default)
    if not is_integer(n) or n < 0, do: raise(ArgumentError, "offset must be nonnegative")
    n
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
