defmodule PiTools do
  @moduledoc """
  An Elixir port of the core tools of pi (https://github.com/earendil-works/pi),
  the minimal extensible coding-agent harness.

  Ported tools: read, write, edit, bash, find, grep, ls.

  Faithful to pi's TypeScript implementations in
  `packages/coding-agent/src/core/tools/`:
    * read   -> read.ts   (offset/limit, 2000-line / 50KB head truncation, magic-byte image detection)
    * write  -> write.ts  (creates parent dirs, overwrites)
    * edit   -> edit.ts   (multi-edit exact/fuzzy replacement, BOM + CRLF aware, diff+patch)
    * bash   -> bash.ts   (tail truncation with a full-output temp file, timeout, exit codes)
    * find   -> find.ts   (fd --glob, respects .gitignore, 1000 result limit)
    * grep   -> grep.ts   (rg --json, context, literal/ignore-case, 100/500 limits)
    * ls     -> ls.ts     (sorted, '/' suffix for dirs, 500 entry limit)

  All functions return pi's "tool result" shape as a map:
    %{content: [%{type: "text", text: ...}], details: <map|nil>, is_error: boolean}

  plus convenience helpers `text/1` and `ok?/1`.
  """

  @default_max_lines 2000
  @default_max_bytes 50 * 1024
  @grep_max_line_length 500
  @find_default_limit 1000
  @grep_default_limit 100
  @ls_default_limit 500

  @pi_bin "/app/priv/pi_bin"

  import Bitwise

  # ----------------------------------------------------------------------------
  # Public entry points
  # ----------------------------------------------------------------------------

  def read(path, opts \\ []), do: do_read(path, opts)
  def write(path, content, opts \\ []), do: do_write(path, content, opts)
  def edit(path, edits, opts \\ []), do: do_edit(path, edits, opts)
  def bash(command, opts \\ []), do: do_bash(command, opts)
  def find(pattern, opts \\ []), do: do_find(pattern, opts)
  def grep(pattern, opts \\ []), do: do_grep(pattern, opts)
  def ls(opts \\ []), do: do_ls(opts)

  @doc "Extract the concatenated text of a tool result."
  def text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1[:type] == "text"))
    |> Enum.map_join("\n", & &1[:text])
  end

  def text(other), do: to_string(other)

  @doc "True when the tool result is not an error."
  def ok?(%{is_error: is_error}), do: is_error != true
  def ok?(_), do: true

  defp cwd(opts), do: Keyword.get(opts, :cwd, File.cwd!())
  defp home, do: System.user_home!()

  defp text_result(text, details \\ nil, is_error \\ false) do
    %{content: [%{type: "text", text: text}], details: details, is_error: is_error}
  end

  # ============================================================================
  # Path utilities (path-utils.ts / paths.ts)
  # ============================================================================

  @unicode_spaces ["\u00A0", "\u2000", "\u2001", "\u2002", "\u2003", "\u2004", "\u2005", "\u2006",
                   "\u2007", "\u2008", "\u2009", "\u200A", "\u202F", "\u205F", "\u3000"]

  @doc "Normalize a path the way pi's normalizePath does (unicode spaces, @, ~)."
  def normalize_path(input, opts \\ []) do
    s =
      input
      |> maybe_trim(Keyword.get(opts, :trim))
      |> maybe_normalize_unicode_spaces(Keyword.get(opts, :normalize_unicode_spaces))
      |> maybe_strip_at(Keyword.get(opts, :strip_at_prefix))

    if Keyword.get(opts, :expand_tilde, true) do
      expand_tilde(s, Keyword.get(opts, :home_dir, home()))
    else
      s
    end
  end

  defp maybe_trim(s, true), do: String.trim(s)
  defp maybe_trim(s, _), do: s

  defp maybe_normalize_unicode_spaces(s, true),
    do: Enum.reduce(@unicode_spaces, s, fn u, acc -> String.replace(acc, u, " ") end)

  defp maybe_normalize_unicode_spaces(s, _), do: s

  defp maybe_strip_at(s, true), do: if(String.starts_with?(s, "@"), do: String.slice(s, 1..-1//1), else: s)
  defp maybe_strip_at(s, _), do: s

  defp expand_tilde("~", home), do: home
  defp expand_tilde("~/" <> rest, home), do: Path.join(home, rest)
  defp expand_tilde(s, _home), do: s

  @doc "Resolve a path relative to cwd (pi's resolveToCwd)."
  def resolve_to_cwd(path, base) do
    normalized = normalize_path(path, normalize_unicode_spaces: true, strip_at_prefix: true)
    base = normalize_path(base)
    if Path.type(normalized) == :absolute, do: Path.expand(normalized), else: Path.expand(normalized, base)
  end

  @doc """
  Resolve a read path, trying macOS-style variants (pi's resolveReadPathAsync).
  """
  def resolve_read_path(path, base) do
    resolved = resolve_to_cwd(path, base)

    variants = [
      resolved,
      macos_screenshot_variant(resolved),
      String.normalize(resolved, :nfd),
      curly_quote_variant(resolved),
      String.normalize(curly_quote_variant(resolved), :nfd)
    ]

    Enum.find(variants, resolved, fn v -> File.exists?(v) end)
  end

  defp macos_screenshot_variant(path),
    do: Regex.replace(~r/ (AM|PM)\./i, path, "\u202F\\1.")

  defp curly_quote_variant(path), do: String.replace(path, "'", "\u2019")

  # ============================================================================
  # Truncation utilities (truncate.ts)
  # ============================================================================

  @doc "Format bytes as human-readable size exactly like pi's formatSize."
  def format_size(bytes) when bytes < 1024, do: "#{bytes}B"

  def format_size(bytes) when bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1) |> fmt_trim()}KB"

  def format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1) |> fmt_trim()}MB"

  # JS toFixed(1) always keeps one decimal; emulate.
  defp fmt_trim(f) do
    s = :erlang.float_to_binary(f, decimals: 1)
    s
  end

  defp split_lines_for_counting(""), do: []
  defp split_lines_for_counting(content) do
    lines = String.split(content, "\n")
    if String.ends_with?(content, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  @doc "Truncate from the head, keeping whole lines (truncate.ts truncateHead)."
  def truncate_head(content, opts \\ []) do
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    total_bytes = byte_size(content)
    lines = split_lines_for_counting(content)
    total_lines = length(lines)

    if total_lines <= max_lines and total_bytes <= max_bytes do
      %{content: content, truncated: false, truncated_by: nil, total_lines: total_lines,
        total_bytes: total_bytes, output_lines: total_lines, output_bytes: total_bytes,
        last_line_partial: false, first_line_exceeds_limit: false,
        max_lines: max_lines, max_bytes: max_bytes}
    else
      first_line_bytes = byte_size(Enum.at(lines, 0) || "")

      if first_line_bytes > max_bytes do
        %{content: "", truncated: true, truncated_by: "bytes", total_lines: total_lines,
          total_bytes: total_bytes, output_lines: 0, output_bytes: 0, last_line_partial: false,
          first_line_exceeds_limit: true, max_lines: max_lines, max_bytes: max_bytes}
      else
        {out, _count, truncated_by} =
          lines
          |> Enum.with_index()
          |> Enum.reduce_while({[], 0, "lines"}, fn {line, i}, {acc, bytes, _tb} ->
            line_bytes = byte_size(line) + if(i > 0, do: 1, else: 0)

            cond do
              length(acc) >= max_lines ->
                {:halt, {acc, bytes, "lines"}}

              bytes + line_bytes > max_bytes ->
                {:halt, {acc, bytes, "bytes"}}

              true ->
                {:cont, {acc ++ [line], bytes + line_bytes, "lines"}}
            end
          end)

        truncated_by = if length(out) >= max_lines, do: "lines", else: truncated_by
        output_content = Enum.join(out, "\n")

        %{content: output_content, truncated: true, truncated_by: truncated_by,
          total_lines: total_lines, total_bytes: total_bytes, output_lines: length(out),
          output_bytes: byte_size(output_content), last_line_partial: false,
          first_line_exceeds_limit: false, max_lines: max_lines, max_bytes: max_bytes}
      end
    end
  end

  @doc "Truncate from the tail, keeping whole lines (truncate.ts truncateTail)."
  def truncate_tail(content, opts \\ []) do
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    total_bytes = byte_size(content)
    lines = split_lines_for_counting(content)
    total_lines = length(lines)

    if total_lines <= max_lines and total_bytes <= max_bytes do
      %{content: content, truncated: false, truncated_by: nil, total_lines: total_lines,
        total_bytes: total_bytes, output_lines: total_lines, output_bytes: total_bytes,
        last_line_partial: false, first_line_exceeds_limit: false,
        max_lines: max_lines, max_bytes: max_bytes}
    else
      rev = Enum.reverse(lines)

      {out, _count, _bytes, truncated_by, last_line_partial} =
        rev
        |> Enum.with_index()
        |> Enum.reduce_while({[], 0, 0, "lines", false}, fn {line, _i}, {acc, bytes, n, _tb, partial} ->
          line_bytes = byte_size(line) + if(n > 0, do: 1, else: 0)

          cond do
            n >= max_lines ->
              {:halt, {acc, bytes, n, "lines", partial}}

            bytes + line_bytes > max_bytes ->
              if acc == [] do
                trunc = truncate_string_to_bytes_from_end(line, max_bytes)
                {:halt, {[trunc], byte_size(trunc), 1, "bytes", true}}
              else
                {:halt, {acc, bytes, n, "bytes", partial}}
              end

            true ->
              {:cont, {[line | acc], bytes + line_bytes, n + 1, "lines", partial}}
          end
        end)

      truncated_by = if length(out) >= max_lines, do: "lines", else: truncated_by
      output_content = Enum.join(out, "\n")

      %{content: output_content, truncated: true, truncated_by: truncated_by,
        total_lines: total_lines, total_bytes: total_bytes, output_lines: length(out),
        output_bytes: byte_size(output_content), last_line_partial: last_line_partial,
        first_line_exceeds_limit: false, max_lines: max_lines, max_bytes: max_bytes}
    end
  end

  defp truncate_string_to_bytes_from_end(str, max_bytes) do
    buf = :binary.bin_to_list(str)

    if length(buf) <= max_bytes do
      str
    else
      start = length(buf) - max_bytes
      start = skip_continuation(buf, start)
      bin = :binary.list_to_bin(Enum.slice(buf, start..-1//1))
      # Ensure valid UTF-8 by replacing any leading partial char.
      case :unicode.characters_to_binary(bin) do
        b when is_binary(b) -> b
        _ -> bin
      end
    end
  end

  defp skip_continuation(buf, i) do
    len = length(buf)
    if i < len and Bitwise.band(Enum.at(buf, i), 0xC0) == 0x80, do: skip_continuation(buf, i + 1), else: i
  end

  @doc "Truncate a single line to max_chars with a suffix (truncate.ts truncateLine)."
  def truncate_line(line, max_chars \\ @grep_max_line_length) do
    if String.length(line) <= max_chars do
      {line, false}
    else
      {String.slice(line, 0, max_chars) <> "... [truncated]", true}
    end
  end

  # ============================================================================
  # read tool (read.ts)
  # ============================================================================

  defp do_read(path, opts) do
    base = cwd(opts)
    offset = Keyword.get(opts, :offset)
    limit = Keyword.get(opts, :limit)

    abs = resolve_read_path(path, base)

    cond do
      not File.exists?(abs) ->
        text_result("Path not found: #{abs}", nil, true)

      File.dir?(abs) ->
        text_result("Cannot read a directory: #{path}", nil, true)

      true ->
        case File.read(abs) do
          {:ok, binary} ->
            case detect_image_mime(binary) do
              nil ->
                read_text(binary, path, offset, limit)

              mime ->
                # pi sends images as attachments. Without an image-capable model attached,
                # report the detected type and the image size in the text block.
                text_result("Read image file [#{mime}]", %{mime: mime, bytes: byte_size(binary)})
            end

          {:error, reason} ->
            text_result("#{path}: #{:file.format_error(reason)}", nil, true)
        end
    end
  end

  defp read_text(binary, path, offset, limit) do
    content = String.replace(binary, "\r\n", "\n")
    all_lines = String.split(content, "\n")
    total = length(all_lines)

    start_line = if offset, do: max(0, offset - 1), else: 0
    start_display = start_line + 1

    if start_line >= total do
      text_result("Offset #{offset} is beyond end of file (#{total} lines total)", nil, true)
    else
      {selected, user_limited} =
        if limit != nil do
          end_line = min(start_line + limit, total)
          chosen = Enum.slice(all_lines, start_line..(end_line - 1)//1)
          {Enum.join(chosen, "\n"), end_line - start_line}
        else
          {Enum.join(Enum.drop(all_lines, start_line), "\n"), nil}
        end

      truncation = truncate_head(selected)

      cond do
        truncation.first_line_exceeds_limit ->
          first_line = Enum.at(all_lines, start_line)
          first_line_size = format_size(byte_size(first_line))
          msg = "[Line #{start_display} is #{first_line_size}, exceeds #{format_size(@default_max_bytes)} limit. Use bash: sed -n '#{start_display}p' #{path} | head -c #{@default_max_bytes}]"
          text_result(msg, %{truncation: truncation})

        truncation.truncated ->
          end_display = start_display + truncation.output_lines - 1
          next_offset = end_display + 1

          msg =
            if truncation.truncated_by == "lines" do
              truncation.content <> "\n\n[Showing lines #{start_display}-#{end_display} of #{total}. Use offset=#{next_offset} to continue.]"
            else
              truncation.content <> "\n\n[Showing lines #{start_display}-#{end_display} of #{total} (#{format_size(@default_max_bytes)} limit). Use offset=#{next_offset} to continue.]"
            end

          text_result(msg, %{truncation: truncation})

        user_limited != nil and start_line + user_limited < total ->
          remaining = total - (start_line + user_limited)
          next_offset = start_line + user_limited + 1
          text_result("#{truncation.content}\n\n[#{remaining} more lines in file. Use offset=#{next_offset} to continue.]")

        true ->
          text_result(truncation.content)
      end
    end
  end

  @doc """
  Detect a supported image MIME type from file content, matching pi's mime.ts.
  Returns nil for non-images or unsupported variants (e.g. animated PNG, JPEG 2000).
  """
  def detect_image_mime(binary) when is_binary(binary) do
    cond do
      starts_with_bytes?(binary, [0xFF, 0xD8, 0xFF]) ->
        if byte_at(binary, 3) == 0xF7, do: nil, else: "image/jpeg"

      starts_with_bytes?(binary, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ->
        if is_png?(binary) and not is_animated_png?(binary), do: "image/png", else: nil

      starts_with_ascii?(binary, 0, "GIF87a") or starts_with_ascii?(binary, 0, "GIF89a") ->
        "image/gif"

      starts_with_ascii?(binary, 0, "RIFF") and starts_with_ascii?(binary, 8, "WEBP") ->
        "image/webp"

      starts_with_ascii?(binary, 0, "BM") and is_bmp?(binary) ->
        "image/bmp"

      true ->
        nil
    end
  end

  def detect_image_mime(_), do: nil

  defp starts_with_bytes?(bin, bytes) do
    byte_size(bin) >= length(bytes) and binary_part(bin, 0, length(bytes)) == :binary.list_to_bin(bytes)
  end

  defp byte_at(bin, i) when i < byte_size(bin), do: :binary.at(bin, i)
  defp byte_at(_bin, _i), do: nil

  defp starts_with_ascii?(bin, offset, text) do
    size = byte_size(text)
    byte_size(bin) >= offset + size and binary_part(bin, offset, size) == text
  end

  defp is_png?(bin) do
    byte_size(bin) >= 16 and read_uint32_be(bin, 8) == 13 and starts_with_ascii?(bin, 12, "IHDR")
  end

  defp is_animated_png?(bin) do
    do_animated(bin, 8, byte_size(bin))
  end

  defp do_animated(_bin, offset, size) when offset + 8 > size, do: false

  defp do_animated(bin, offset, size) do
    chunk_length = read_uint32_be(bin, offset)
    chunk_type_offset = offset + 4

    cond do
      starts_with_ascii?(bin, chunk_type_offset, "acTL") -> true
      starts_with_ascii?(bin, chunk_type_offset, "IDAT") -> false
      true ->
        next_offset = offset + 8 + chunk_length + 4
        if next_offset <= offset or next_offset > size, do: false, else: do_animated(bin, next_offset, size)
    end
  end

  defp is_bmp?(bin) do
    if byte_size(bin) < 26 do
      false
    else
      declared_file_size = read_uint32_le(bin, 2)
      pixel_data_offset = read_uint32_le(bin, 10)
      dib_header_size = read_uint32_le(bin, 14)

      cond do
        declared_file_size != 0 and declared_file_size < 26 -> false
        pixel_data_offset < 14 + dib_header_size -> false
        declared_file_size != 0 and pixel_data_offset >= declared_file_size -> false
        true -> bmp_planes_and_bpp(bin, dib_header_size)
      end
    end
  end

  defp bmp_planes_and_bpp(bin, 12) do
    read_uint16_le(bin, 22) == 1 and read_uint16_le(bin, 24) in [1, 4, 8, 16, 24, 32]
  end

  defp bmp_planes_and_bpp(bin, dib) when dib >= 40 and dib <= 124 do
    if byte_size(bin) < 30 do
      false
    else
      read_uint16_le(bin, 26) == 1 and read_uint16_le(bin, 28) in [1, 4, 8, 16, 24, 32]
    end
  end

  defp bmp_planes_and_bpp(_bin, _dib), do: false

  defp read_uint16_le(bin, o) do
    (byte_at(bin, o) || 0) + ((byte_at(bin, o + 1) || 0) <<< 8)
  end

  defp read_uint32_be(bin, o) do
    (byte_at(bin, o) || 0) * 0x1000000 +
      ((byte_at(bin, o + 1) || 0) <<< 16) +
      ((byte_at(bin, o + 2) || 0) <<< 8) +
      (byte_at(bin, o + 3) || 0)
  end

  defp read_uint32_le(bin, o) do
    (byte_at(bin, o) || 0) +
      ((byte_at(bin, o + 1) || 0) <<< 8) +
      ((byte_at(bin, o + 2) || 0) <<< 16) +
      (byte_at(bin, o + 3) || 0) * 0x1000000
  end

  # ============================================================================
  # write tool (write.ts)
  # ============================================================================

  defp do_write(path, content, opts) do
    base = cwd(opts)
    abs = resolve_to_cwd(path, base)

    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, content) do
      text_result("Successfully wrote to #{path}")
    else
      {:error, reason} -> text_result("#{path}: #{:file.format_error(reason)}", nil, true)
    end
  end

  # ============================================================================
  # edit tool (edit.ts + edit-diff.ts)
  # ============================================================================

  def edit_result(path, edits, opts \\ []) do
    do_edit(path, edits, opts)
  end

  defp do_edit(path, edits, opts) do
    base = cwd(opts)
    abs = resolve_to_cwd(path, base)

    edits =
      Enum.map(edits, fn e ->
        %{oldText: to_string(Map.get(e, :oldText) || Map.get(e, "oldText")),
          newText: to_string(Map.get(e, :newText) || Map.get(e, "newText"))}
      end)

    cond do
      edits == [] ->
        text_result("Edit tool input is invalid. edits must contain at least one replacement.", nil, true)

      not File.exists?(abs) ->
        text_result("Could not edit file: #{path}. Error code: ENOENT.", nil, true)

      true ->
        case File.read(abs) do
          {:ok, raw} -> apply_edit(abs, path, edits, raw)
          {:error, reason} -> text_result("Could not edit file: #{path}. #{:file.format_error(reason)}.", nil, true)
        end
    end
  end

  defp apply_edit(abs, path, edits, raw) do
    {bom, content} = split_bom(raw)
    original_ending = detect_line_ending(content)
    normalized = normalize_to_lf(content)

    try do
      {base_content, new_content} = apply_edits_to_normalized_content(normalized, edits, path)
      final_content = bom <> restore_line_endings(new_content, original_ending)
      File.write!(abs, final_content)

      {diff, first_changed} = generate_diff_string(base_content, new_content)
      patch = generate_unified_patch(path, base_content, new_content)

      %{
        content: [%{type: "text", text: "Successfully replaced #{length(edits)} block(s) in #{path}."}],
        details: %{diff: diff, patch: patch, first_changed_line: first_changed},
        is_error: false
      }
    rescue
      e in RuntimeError -> text_result(Exception.message(e), nil, true)
    end
  end

  def split_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {"\uFEFF", rest}
  def split_bom(bin), do: {"", bin}

  def detect_line_ending(content) do
    crlf = :binary.match(content, "\r\n")
    lf = :binary.match(content, "\n")

    cond do
      lf == :nomatch -> "\n"
      crlf == :nomatch -> "\n"
      elem(crlf, 0) < elem(lf, 0) -> "\r\n"
      true -> "\n"
    end
  end

  def normalize_to_lf(text) do
    text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
  end

  def restore_line_endings(text, "\r\n"), do: String.replace(text, "\n", "\r\n")
  def restore_line_endings(text, "\n"), do: text

  @doc "Normalize for fuzzy matching, mirroring normalizeForFuzzyMatch."
  def normalize_for_fuzzy_match(text) do
    text
    |> apply_nfkc()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.replace(~r/[‘’‚‛]/u, "'")
    |> String.replace(~r/[“”„‟]/u, "\"")
    |> String.replace(~r/[‐‑‒–—―−]/u, "-")
    |> String.replace(~r/[  -   　]/u, " ")
  end

  defp apply_nfkc(text) do
    case :unicode.characters_to_nfkc_binary(text) do
      b when is_binary(b) -> b
      _ -> text
    end
  end

  @doc "Find oldText in content, exact first then fuzzy (edit-diff.ts fuzzyFindText)."
  def fuzzy_find_text(content, old_text) do
    case :binary.match(content, old_text) do
      {i, len} ->
        %{found: true, index: i, match_length: len, used_fuzzy_match: false,
          content_for_replacement: content}

      :nomatch ->
        fuzzy_content = normalize_for_fuzzy_match(content)
        fuzzy_old = normalize_for_fuzzy_match(old_text)

        case :binary.match(fuzzy_content, fuzzy_old) do
          {i, len} ->
            %{found: true, index: i, match_length: len, used_fuzzy_match: true,
              content_for_replacement: fuzzy_content}

          :nomatch ->
            %{found: false, index: -1, match_length: 0, used_fuzzy_match: false,
              content_for_replacement: content}
        end
    end
  end

  defp count_occurrences(content, old_text) do
    fc = normalize_for_fuzzy_match(content)
    fo = normalize_for_fuzzy_match(old_text)
    if fo == "", do: 0, else: length(String.split(fc, fo)) - 1
  end

  defp apply_edits_to_normalized_content(normalized_content, edits, path) do
    normalized_edits =
      Enum.map(edits, fn e ->
        %{oldText: normalize_to_lf(e.oldText), newText: normalize_to_lf(e.newText)}
      end)

    Enum.with_index(normalized_edits)
    |> Enum.each(fn {e, i} ->
      if e.oldText == "" do
        raise empty_old_text_error(path, i, length(normalized_edits))
      end
    end)

    initial_matches = Enum.map(normalized_edits, fn e -> fuzzy_find_text(normalized_content, e.oldText) end)
    used_fuzzy = Enum.any?(initial_matches, & &1.used_fuzzy_match)
    replacement_base = if used_fuzzy, do: normalize_for_fuzzy_match(normalized_content), else: normalized_content

    matched =
      normalized_edits
      |> Enum.with_index()
      |> Enum.map(fn {e, i} ->
        m = fuzzy_find_text(replacement_base, e.oldText)

        if not m.found do
          raise not_found_error(path, i, length(normalized_edits))
        end

        occ = count_occurrences(replacement_base, e.oldText)

        if occ > 1 do
          raise duplicate_error(path, i, length(normalized_edits), occ)
        end

        %{edit_index: i, match_index: m.index, match_length: m.match_length, new_text: e.newText}
      end)

    sorted = Enum.sort_by(matched, & &1.match_index)

    sorted
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [prev, cur] ->
      if prev.match_index + prev.match_length > cur.match_index do
        raise "edits[#{prev.edit_index}] and edits[#{cur.edit_index}] overlap in #{path}. Merge them into one edit or target disjoint regions."
      end
    end)

    base_content = normalized_content

    new_content =
      if used_fuzzy do
        apply_replacements_preserving_unchanged_lines(normalized_content, replacement_base, sorted)
      else
        apply_replacements(replacement_base, sorted)
      end

    if base_content == new_content do
      raise no_change_error(path, length(normalized_edits))
    end

    {base_content, new_content}
  end

  defp empty_old_text_error(path, _i, 1), do: "oldText must not be empty in #{path}."

  defp empty_old_text_error(path, i, _),
    do: "edits[#{i}].oldText must not be empty in #{path}."

  defp not_found_error(path, _i, 1),
    do: "Could not find the exact text in #{path}. The old text must match exactly including all whitespace and newlines."

  defp not_found_error(path, i, _),
    do: "Could not find edits[#{i}] in #{path}. The oldText must match exactly including all whitespace and newlines."

  defp duplicate_error(path, _i, 1, occ),
    do: "Found #{occ} occurrences of the text in #{path}. The text must be unique. Please provide more context to make it unique."

  defp duplicate_error(path, i, _, occ),
    do: "Found #{occ} occurrences of edits[#{i}] in #{path}. Each oldText must be unique. Please provide more context to make it unique."

  defp no_change_error(path, 1),
    do: "No changes made to #{path}. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."

  defp no_change_error(path, _),
    do: "No changes made to #{path}. The replacements produced identical content."

  defp apply_replacements(content, replacements, offset \\ 0) do
    replacements
    |> Enum.reverse()
    |> Enum.reduce(content, fn r, result ->
      mi = r.match_index - offset
      mlen = r.match_length
      part1 = binary_part(result, 0, mi)
      part2 = binary_part(result, mi + mlen, byte_size(result) - mi - mlen)
      part1 <> r.new_text <> part2
    end)
  end

  defp split_lines_with_endings(content) do
    Regex.scan(~r/[^\n]*\n|[^\n]+/, content) |> Enum.map(&hd/1)
  end

  defp get_line_spans(content) do
    {spans, _} =
      split_lines_with_endings(content)
      |> Enum.map_reduce(0, fn line, off ->
        {%{start: off, end: off + byte_size(line)}, off + byte_size(line)}
      end)

    spans
  end

  defp apply_replacements_preserving_unchanged_lines(original, base, replacements) do
    original_lines = split_lines_with_endings(original)
    base_lines = get_line_spans(base)

    if length(original_lines) != length(base_lines) do
      raise "Cannot preserve unchanged lines because the base content has a different line count."
    end

    groups =
      replacements
      |> Enum.sort_by(& &1.match_index)
      |> Enum.reduce([], fn r, groups ->
        range = replacement_line_range(base_lines, r)

        case groups do
          [current | rest] when range.start < current.end_line ->
            [%{current | end_line: max(current.end_line, range.end_line), replacements: current.replacements ++ [r]} | rest]

          _ ->
            [%{start_line: range.start, end_line: range.end_line, replacements: [r]} | groups]
        end
      end)
      |> Enum.reverse()

    {result, original_index} =
      Enum.reduce(groups, {"", 0}, fn group, {acc, original_index} ->
        acc = acc <> Enum.join(safe_slice(original_lines, original_index, group.start_line - 1), "")
        group_start = Enum.at(base_lines, group.start_line).start
        group_end = Enum.at(base_lines, group.end_line - 1).end
        segment = binary_part(base, group_start, group_end - group_start)
        acc = acc <> apply_replacements(segment, group.replacements, group_start)
        {acc, group.end_line}
      end)

    result <> Enum.join(safe_slice(original_lines, original_index, length(original_lines) - 1), "")
  end

  defp safe_slice(list, from, to) do
    if to < from do
      []
    else
      Enum.slice(list, from..to//1)
    end
  end

  defp replacement_line_range(lines, r) do
    replacement_start = r.match_index
    replacement_end = r.match_index + r.match_length
    n = length(lines)

    start_line =
      Enum.find_index(Enum.with_index(lines), fn {line, _i} ->
        replacement_start >= line.start and replacement_start < line.end
      end)

    if start_line == nil do
      raise "Replacement range is outside the base content."
    end

    end_line = find_end_line(lines, start_line, replacement_end, n)
    %{start: start_line, end_line: end_line + 1}
  end

  defp find_end_line(lines, i, replacement_end, n) do
    if i < n and Enum.at(lines, i).end < replacement_end do
      find_end_line(lines, i + 1, replacement_end, n)
    else
      if i >= n, do: raise("Replacement range is outside the base content."), else: i
    end
  end

  # --- diff generation (uses the system `diff` for a standard unified patch) ---

  @doc "Generate a standard unified patch (needs a temp file; uses diff lib in TS)."
  def generate_unified_patch(path, old, new, context \\ 4) do
    tmp = System.tmp_dir!()
    a = Path.join(tmp, "pi_patch_a_#{:erlang.unique_integer([:positive])}")
    b = Path.join(tmp, "pi_patch_b_#{:erlang.unique_integer([:positive])}")
    File.write!(a, old)
    File.write!(b, new)

    try do
      {out, _} =
        System.cmd("diff", ["-u", "-U#{context}", "--label", path, "--label", path, a, b],
          stderr_to_stdout: true)

      out
    after
      File.rm(a)
      File.rm(b)
    end
  end

@doc "Generate pi's display-oriented diff with line numbers."
  def generate_diff_string(old, new, context_lines \\ 4) do
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")
    max_line = max(length(old_lines), length(new_lines))
    width = String.length(Integer.to_string(max_line))
    parts = diff_parts(old, new)

    {output, _old_n, _new_n, _last_change, first_changed} =
      parts
      |> Enum.with_index()
      |> Enum.reduce({[], 1, 1, false, nil}, fn {{tag, value}, i}, {out, old_n, new_n, last_change, first} ->
        raw = String.split(value, "\n")
        raw = if List.last(raw) == "", do: Enum.drop(raw, -1), else: raw

        cond do
          tag == :added ->
            {first, _} = if first == nil, do: {new_n, nil}, else: {first, nil}

            {lines, new_n} =
              Enum.reduce(raw, {out, new_n}, fn line, {o, nn} ->
                {o ++ ["+" <> pad(nn, width) <> " " <> line], nn + 1}
              end)

            {lines, old_n, new_n, true, first}

          tag == :removed ->
            {first, _} = if first == nil, do: {new_n, nil}, else: {first, nil}

            {lines, old_n} =
              Enum.reduce(raw, {out, old_n}, fn line, {o, on} ->
                {o ++ ["-" <> pad(on, width) <> " " <> line], on + 1}
              end)

            {lines, old_n, new_n, true, first}

          true ->
            next_is_change = next_part_is_change?(parts, i)
            has_leading = last_change
            has_trailing = next_is_change

            {lines, old_n, new_n} =
              cond do
                has_leading and has_trailing ->
                  if length(raw) <= context_lines * 2 do
                    Enum.reduce(raw, {[], old_n, new_n}, fn line, {o, on, nn} ->
                      {o ++ [" " <> pad(on, width) <> " " <> line], on + 1, nn + 1}
                    end)
                  else
                    leading = Enum.slice(raw, 0, context_lines)
                    trailing = Enum.slice(raw, (length(raw) - context_lines)..-1//1)
                    skipped = length(raw) - length(leading) - length(trailing)

                    {o, on, nn} =
                      Enum.reduce(leading, {[], old_n, new_n}, fn line, {o, on, nn} ->
                        {o ++ [" " <> pad(on, width) <> " " <> line], on + 1, nn + 1}
                      end)

                    o = o ++ [" " <> String.duplicate(" ", width) <> " ..."]
                    on = on + skipped
                    nn = nn + skipped

                    Enum.reduce(trailing, {o, on, nn}, fn line, {o, on, nn} ->
                      {o ++ [" " <> pad(on, width) <> " " <> line], on + 1, nn + 1}
                    end)
                  end

                has_leading ->
                  shown = Enum.slice(raw, 0, context_lines)
                  skipped = length(raw) - length(shown)

                  {o, on, nn} =
                    Enum.reduce(shown, {[], old_n, new_n}, fn line, {o, on, nn} ->
                      {o ++ [" " <> pad(on, width) <> " " <> line], on + 1, nn + 1}
                    end)

                  o = if skipped > 0, do: o ++ [" " <> String.duplicate(" ", width) <> " ..."], else: o
                  {o, on + skipped, nn + skipped}

                has_trailing ->
                  skipped = max(0, length(raw) - context_lines)
                  shown = Enum.slice(raw, skipped..-1//1)
                  prefix = if skipped > 0, do: [" " <> String.duplicate(" ", width) <> " ..."], else: []
                  {o, on, nn} =
                    Enum.reduce(shown, {prefix, old_n + skipped, new_n + skipped}, fn line, {o, on, nn} ->
                      {o ++ [" " <> pad(on, width) <> " " <> line], on + 1, nn + 1}
                    end)
                  {o, on, nn}

                true ->
                  {[], old_n, new_n}
              end

            {out ++ lines, old_n, new_n, false, first}
        end
      end)

    {Enum.join(output, "\n"), first_changed}
  end

  defp next_part_is_change?(parts, i) do
    case Enum.at(parts, i + 1) do
      {tag, _} -> tag == :added or tag == :removed
      nil -> false
    end
  end

  defp lcs_table(a, b) do
    na = length(a)
    nb = length(b)
    da = List.to_tuple(a)
    db = List.to_tuple(b)

    Enum.reduce(Enum.to_list(0..nb), %{}, fn j, acc -> Map.put(acc, {na, j}, 0) end)
    |> then(fn acc ->
      Enum.reduce(Enum.to_list(0..(na - 1)) |> Enum.reverse(), acc, fn i, acc ->
        Enum.reduce(Enum.to_list(0..(nb - 1)) |> Enum.reverse(), acc, fn j, acc ->
          v =
            if elem(da, i) == elem(db, j) do
              1 + Map.get(acc, {i + 1, j + 1}, 0)
            else
              max(Map.get(acc, {i + 1, j}, 0), Map.get(acc, {i, j + 1}, 0))
            end

          Map.put(acc, {i, j}, v)
        end)
      end)
    end)
  end

  defp lcs_ops(a, b, lcs, i, j, acc) do
    ta = List.to_tuple(a)
    tb = List.to_tuple(b)
    na = tuple_size(ta)
    nb = tuple_size(tb)

    cond do
      i >= na -> Enum.reverse(acc) ++ Enum.map(j..(nb - 1)//1, fn jj -> {:equal, elem(tb, jj)} end)
      j >= nb -> Enum.reverse(acc) ++ Enum.map(i..(na - 1)//1, fn ii -> {:equal, elem(ta, ii)} end)
      elem(ta, i) == elem(tb, j) ->
        lcs_ops(a, b, lcs, i + 1, j + 1, [{:equal, elem(ta, i)} | acc])

      Map.get(lcs, {i + 1, j}, 0) >= Map.get(lcs, {i, j + 1}, 0) ->
        lcs_ops(a, b, lcs, i + 1, j, [{:removed, elem(ta, i)} | acc])

      true ->
        lcs_ops(a, b, lcs, i, j + 1, [{:added, elem(tb, j)} | acc])
    end
  end

  defp group_ops(raw) do
    raw
    |> Enum.reduce([], fn {tag, line}, acc ->
      case acc do
        [{^tag, prev} | rest] -> [{tag, prev <> line} | rest]
        _ -> [{tag, line} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Compute diff parts (grouped added/removed/equal), like jsdiff's diffLines.
  # Tokens keep their trailing newline, matching jsdiff line semantics.
  defp diff_parts(old, new) do
    old_lines = tokenize_lines(old)
    new_lines = tokenize_lines(new)
    lcs = lcs_table(old_lines, new_lines)
    raw = lcs_ops(old_lines, new_lines, lcs, 0, 0, [])
    group_ops(raw)
  end

  defp tokenize_lines(""), do: []

  defp tokenize_lines(content) do
    Regex.scan(~r/[^\n]*\n|[^\n]+/, content) |> Enum.map(&hd/1)
  end

  defp pad(n, width), do: String.pad_leading(Integer.to_string(n), width, " ")

  # ============================================================================
  # bash tool (bash.ts)
  # ============================================================================

  defp do_bash(command, opts) do
    base = cwd(opts)
    timeout = Keyword.get(opts, :timeout)
    shell = Keyword.get(opts, :shell, "/bin/bash")

    if not File.dir?(base) do
      text_result("Working directory does not exist: #{base}\nCannot execute bash commands.", nil, true)
    else
      started = System.monotonic_time(:millisecond)
      run_bash(command, base, timeout, shell, started)
    end
  end

  defp run_bash(command, base, timeout, shell, started) do
    # Capture all output to a temp file.
    capture = Path.join(System.tmp_dir!(), "pi-bash-capture-#{:erlang.unique_integer([:positive])}.log")
    out_fd = File.open!(capture, [:write, :binary])

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      cd: base,
      args: ["-c", command]
    ]

    port = Port.open({:spawn_executable, shell}, port_opts)

    {_output, exit_code, timed_out} = collect_port(port, out_fd, timeout, [], started)

    File.close(out_fd)
    full = File.read!(capture)

    truncation = truncate_tail(full)

    # pi persists the full output to a temp file when truncated and points at it.
    full_output_path =
      if truncation.truncated do
        path = Path.join(System.tmp_dir!(), "pi-bash-" <> random_hex(8) <> ".log")
        File.write!(path, full)
        File.chmod!(path, 0o600)
        path
      end

    File.rm(capture)

    {output_text, details} = format_bash_output(truncation, full, full_output_path)

    cond do
      timed_out ->
        text_result(append_status(output_text, "Command timed out after #{timeout} seconds"), details, true)

      exit_code == nil ->
        text_result(append_status(output_text, "Command terminated without an exit code"), details, true)

      exit_code != 0 ->
        text_result(append_status(output_text, "Command exited with code #{exit_code}"),
          Map.put(details || %{}, :exit_code, exit_code), true)

      true ->
        text_result(output_text, details)
    end
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end

  defp collect_port(port, out_fd, timeout, acc, started) do
    deadline = if timeout, do: started + timeout * 1000, else: nil
    collect_port_loop(port, out_fd, deadline, acc, false)
  end

  defp collect_port_loop(port, out_fd, deadline, acc, timed_out) do
    wait = if deadline, do: max(deadline - System.monotonic_time(:millisecond), 0), else: :infinity

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        IO.binwrite(out_fd, data)
        collect_port_loop(port, out_fd, deadline, [data | acc], timed_out)

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(Enum.reverse(acc)), status, timed_out}
    after
      wait ->
        if deadline != nil and not timed_out do
          kill_port(port)
          drain_and_wait(port, out_fd, Enum.reverse(acc))
        else
          {IO.iodata_to_binary(Enum.reverse(acc)), nil, true}
        end
    end
  end

  defp drain_and_wait(port, out_fd, acc) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        IO.binwrite(out_fd, data)
        drain_and_wait(port, out_fd, [data | acc])

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(Enum.reverse(acc)), status, true}
    after
      2000 ->
        {IO.iodata_to_binary(Enum.reverse(acc)), nil, true}
    end
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("sh", ["-c", "kill -TERM -#{os_pid} 2>/dev/null || kill -TERM #{os_pid} 2>/dev/null"],
          stderr_to_stdout: true)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp format_bash_output(truncation, full, full_output_path) do
    text = if truncation.content == "", do: "(no output)", else: truncation.content

    if truncation.truncated do
      details = %{truncation: truncation, full_output_path: full_output_path, full_output: full}
      start_line = truncation.total_lines - truncation.output_lines + 1
      end_line = truncation.total_lines

      notice =
        cond do
          truncation.last_line_partial ->
            last_line_bytes = last_line_bytes(full)
            "[Showing last #{format_size(truncation.output_bytes)} of line #{end_line} (line is #{format_size(last_line_bytes)}). Full output: #{full_output_path}]"

          truncation.truncated_by == "lines" ->
            "[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines}. Full output: #{full_output_path}]"

          true ->
            "[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines} (#{format_size(@default_max_bytes)} limit). Full output: #{full_output_path}]"
        end

      {text <> "\n\n" <> notice, details}
    else
      {text, nil}
    end
  end

  defp last_line_bytes(full) do
    lines = split_lines_for_counting(full)
    if lines == [], do: 0, else: byte_size(List.last(lines))
  end

  defp append_status(text, status) do
    if text != "", do: text <> "\n\n" <> status, else: status
  end

  # ============================================================================
  # find tool (find.ts)
  # ============================================================================

  defp do_find(pattern, opts) do
    base = cwd(opts)
    search_dir = Keyword.get(opts, :path, ".")
    limit = Keyword.get(opts, :limit, @find_default_limit)
    search_path = resolve_to_cwd(search_dir, base)

    fd = pi_bin("fd", opts)

    if not File.dir?(search_path) and not File.exists?(search_path) do
      text_result("Path not found: #{search_path}", nil, true)
    else
      base_args = ["--glob", "--color=never", "--hidden"]

      inside_git = inside_git_repo?(search_path)
      base_args = if inside_git, do: base_args, else: base_args ++ ["--no-require-git"]
      base_args = base_args ++ ["--max-results", Integer.to_string(limit)]

      {args, effective_pattern} =
        if String.contains?(pattern, "/") do
          pat =
            if not String.starts_with?(pattern, "/") and not String.starts_with?(pattern, "**/") and pattern != "**" do
              "**/" <> pattern
            else
              pattern
            end

          {base_args ++ ["--full-path"], pat}
        else
          {base_args, pattern}
        end

      full_args = args ++ ["--", effective_pattern, search_path]
      label = Keyword.get(opts, :fd_path, fd)

      {out, code, stderr} = run_capture(label, full_args)

      lines =
        out
        |> String.split("\n")
        |> Enum.map(&(&1 |> String.replace_suffix("\r", "") |> String.trim()))
        |> Enum.reject(&(&1 == ""))

      if code != 0 and lines == [] do
        msg = if String.trim(stderr) != "", do: String.trim(stderr), else: String.trim(out)
        text_result(msg, nil, true)
      else
        if lines == [] do
          text_result("No files found matching pattern")
        else
          relativized = Enum.map(lines, &relativize_find_result(&1, search_path))
          result_limit_reached = length(relativized) >= limit
          raw_output = Enum.join(relativized, "\n")
          truncation = truncate_head(raw_output, max_lines: 1_000_000_000)
          result_output = truncation.content
          {notices, details} = find_notices(result_limit_reached, limit, truncation)

          result_output = if notices == [], do: result_output, else: result_output <> "\n\n[#{Enum.join(notices, ". ")}]"
          text_result(result_output, if(details == %{}, do: nil, else: details))
        end
      end
    end
  end

  defp find_notices(result_limit_reached, limit, truncation) do
    notices = []
    details = %{}

    {notices, details} =
      if result_limit_reached do
        {notices ++ ["#{limit} results limit reached. Use limit=#{limit * 2} for more, or refine pattern"],
         Map.put(details, :result_limit_reached, limit)}
      else
        {notices, details}
      end

    if truncation.truncated do
      {notices ++ ["#{format_size(@default_max_bytes)} limit reached"], Map.put(details, :truncation, truncation)}
    else
      {notices, details}
    end
  end

  defp inside_git_repo?(path) do
    do_inside_git_repo?(path)
  end

  defp do_inside_git_repo?(current) do
    if File.exists?(Path.join(current, ".git")) do
      true
    else
      parent = Path.dirname(current)
      if parent == current, do: false, else: do_inside_git_repo?(parent)
    end
  end

  @doc "Relativize a find result against the search root (find.ts relativizeFindResultPath)."
  def relativize_find_result(result_path, search_path) do
    had_trailing = String.ends_with?(result_path, "/")

    relative =
      if Path.type(result_path) == :absolute do
        Path.relative_to(result_path, search_path)
      else
        result_path
      end

    if had_trailing and not String.ends_with?(relative, "/"), do: relative <> "/", else: relative
  end

  # ============================================================================
  # grep tool (grep.ts)
  # ============================================================================

  defp do_grep(pattern, opts) do
    base = cwd(opts)
    search_dir = Keyword.get(opts, :path, ".")
    glob = Keyword.get(opts, :glob)
    ignore_case = Keyword.get(opts, :ignore_case, false)
    literal = Keyword.get(opts, :literal, false)
    context = Keyword.get(opts, :context, 0)
    limit = Keyword.get(opts, :limit, @grep_default_limit)
    rg = pi_bin("rg", opts)

    search_path = resolve_to_cwd(search_dir, base)

    if not File.exists?(search_path) do
      text_result("Path not found: #{search_path}", nil, true)
    else
      is_dir = File.dir?(search_path)
      context_value = if context != nil and context > 0, do: context, else: 0
      effective_limit = max(1, limit)

      args = ["--json", "--line-number", "--color=never", "--hidden"]
      args = if ignore_case, do: args ++ ["--ignore-case"], else: args
      args = if literal, do: args ++ ["--fixed-strings"], else: args
      args = if glob, do: args ++ ["--glob", glob], else: args
      args = args ++ ["--", pattern, search_path]

      label = Keyword.get(opts, :rg_path, rg)
      {out, code, stderr} = run_capture(label, args)

      if code != 0 and code != 1 do
        msg = if String.trim(stderr) != "", do: String.trim(stderr), else: String.trim(out)
        text_result(msg, nil, true)
      else
        matches = parse_rg_matches(out, effective_limit)
        format_grep_matches(matches, search_path, is_dir, context_value, effective_limit, pattern, opts)
      end
    end
  end

  defp parse_rg_matches(out, limit) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({[], 0}, fn line, {acc, count} ->
      if count >= limit do
        {:halt, {acc, count}}
      else
        case Jason.decode(line) do
          {:ok, %{"type" => "match", "data" => data}} ->
            path = get_in(data, ["path", "text"])
            line_number = data["line_number"]
            line_text = get_in(data, ["lines", "text"])

            if path != nil and is_integer(line_number) do
              {:cont, {[{path, line_number, line_text} | acc], count + 1}}
            else
              {:cont, {acc, count}}
            end

          _ ->
            {:cont, {acc, count}}
        end
      end
    end)
    |> then(fn {acc, count} -> {Enum.reverse(acc), count} end)
  end

  defp format_grep_matches({[], _}, _, _, _, _, _, _), do: text_result("No matches found")

  defp format_grep_matches({matches, match_count}, search_path, is_dir, context_value, effective_limit, _pattern, opts) do
    limit = effective_limit
    file_cache = Keyword.get(opts, :file_cache, %{})

    {output_lines, _cache, lines_truncated} =
      Enum.reduce(matches, {[], file_cache, false}, fn {file_path, line_number, line_text}, {out, cache, lt} ->
        relative = format_grep_path(file_path, search_path, is_dir)

        if context_value == 0 and line_text != nil do
          sanitized =
            line_text
            |> String.replace("\r\n", "\n")
            |> String.replace("\r", "")
            |> String.replace_suffix("\n", "")

          {text, was_truncated} = truncate_line(sanitized)
          {out ++ ["#{relative}:#{line_number}: #{text}"], cache, lt or was_truncated}
        else
          {lines, cache} = read_file_lines(file_path, cache)
          {block, was_truncated} = format_grep_block(lines, relative, line_number, context_value)
          {out ++ block, cache, lt or was_truncated}
        end
      end)

    raw_output = Enum.join(output_lines, "\n")
    truncation = truncate_head(raw_output, max_lines: 1_000_000_000)
    output = truncation.content

    match_limit_reached = match_count >= limit
    {notices, details} = grep_notices(match_limit_reached, limit, truncation, lines_truncated)
    output = if notices == [], do: output, else: output <> "\n\n[#{Enum.join(notices, ". ")}]"
    text_result(output, if(details == %{}, do: nil, else: details))
  end

  defp format_grep_block([], _relative, _line_number, _context), do: {[], false}

  defp format_grep_block(lines, relative, line_number, context_value) do
    total = length(lines)
    start = if context_value > 0, do: max(1, line_number - context_value), else: line_number
    finish = if context_value > 0, do: min(total, line_number + context_value), else: line_number

    Enum.reduce(start..finish, {[], false}, fn current, {acc, truncated} ->
      line_text = Enum.at(lines, current - 1) || ""
      sanitized = String.replace(line_text, "\r", "")
      {text, was_truncated} = truncate_line(sanitized)
      truncated = truncated or was_truncated

      entry =
        if current == line_number do
          "#{relative}:#{current}: #{text}"
        else
          "#{relative}-#{current}- #{text}"
        end

      {acc ++ [entry], truncated}
    end)
  end

  defp format_grep_path(file_path, search_path, true) do
    relative = Path.relative_to(file_path, search_path)

    if relative != "" and not String.starts_with?(relative, "..") do
      String.replace(relative, "\\", "/")
    else
      Path.basename(file_path)
    end
  end

  defp format_grep_path(file_path, _search_path, false), do: Path.basename(file_path)

  defp read_file_lines(file_path, cache) do
    case Map.get(cache, file_path) do
      nil ->
        lines =
          case File.read(file_path) do
            {:ok, content} -> String.split(normalize_to_lf(content), "\n")
            {:error, _} -> []
          end

        {lines, Map.put(cache, file_path, lines)}

      lines ->
        {lines, cache}
    end
  end

  defp grep_notices(match_limit_reached, limit, truncation, lines_truncated) do
    notices = []
    details = %{}

    {notices, details} =
      if match_limit_reached do
        {notices ++ ["#{limit} matches limit reached. Use limit=#{limit * 2} for more, or refine pattern"],
         Map.put(details, :match_limit_reached, limit)}
      else
        {notices, details}
      end

    {notices, details} =
      if truncation.truncated do
        {notices ++ ["#{format_size(@default_max_bytes)} limit reached"], Map.put(details, :truncation, truncation)}
      else
        {notices, details}
      end

    if lines_truncated do
      {notices ++ ["Some lines truncated to #{@grep_max_line_length} chars. Use read tool to see full lines"],
       Map.put(details, :lines_truncated, true)}
    else
      {notices, details}
    end
  end

  # ============================================================================
  # ls tool (ls.ts)
  # ============================================================================

  defp do_ls(opts) do
    base = cwd(opts)
    path = Keyword.get(opts, :path, ".")
    limit = Keyword.get(opts, :limit, @ls_default_limit)
    dir = resolve_to_cwd(path, base)

    cond do
      not File.exists?(dir) ->
        text_result("Path not found: #{dir}", nil, true)

      not File.dir?(dir) ->
        text_result("Not a directory: #{dir}", nil, true)

      true ->
        case File.ls(dir) do
          {:error, reason} ->
            text_result("Cannot read directory: #{:file.format_error(reason)}", nil, true)

          {:ok, entries} ->
            entries = Enum.sort_by(entries, &String.downcase/1)

            {results, entry_limit_reached} =
              Enum.reduce_while(entries, {[], false}, fn entry, {acc, _} ->
                if length(acc) >= limit do
                  {:halt, {acc, true}}
                else
                  full = Path.join(dir, entry)
                  suffix = if File.dir?(full), do: "/", else: ""

                  case File.stat(full) do
                    {:ok, _} -> {:cont, {acc ++ [entry <> suffix], false}}
                    {:error, _} -> {:cont, {acc, false}}
                  end
                end
              end)

            if results == [] do
              text_result("(empty directory)")
            else
              raw_output = Enum.join(results, "\n")
              truncation = truncate_head(raw_output, max_lines: 1_000_000_000)
              output = truncation.content
              {notices, details} = ls_notices(entry_limit_reached, limit, truncation)
              output = if notices == [], do: output, else: output <> "\n\n[#{Enum.join(notices, ". ")}]"
              text_result(output, if(details == %{}, do: nil, else: details))
            end
        end
    end
  end

  defp ls_notices(entry_limit_reached, limit, truncation) do
    notices = []
    details = %{}

    {notices, details} =
      if entry_limit_reached do
        {notices ++ ["#{limit} entries limit reached. Use limit=#{limit * 2} for more"],
         Map.put(details, :entry_limit_reached, limit)}
      else
        {notices, details}
      end

    if truncation.truncated do
      {notices ++ ["#{format_size(@default_max_bytes)} limit reached"], Map.put(details, :truncation, truncation)}
    else
      {notices, details}
    end
  end

  # ============================================================================
  # binary helpers
  # ============================================================================

  # Run a command, capturing stdout and stderr separately.
  # System.cmd/3 cannot return them separately, so route stderr to a temp file.
  defp run_capture(program, args) do
    err_file = Path.join(System.tmp_dir!(), "pi_err_#{:erlang.unique_integer([:positive])}")

    cmd = Enum.map_join([program | args], " ", &shell_quote/1) <> " 2> " <> shell_quote(err_file)

    {out, code} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: false)

    stderr = if File.exists?(err_file), do: File.read!(err_file), else: ""
    File.rm(err_file)
    {out, code, stderr}
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp pi_bin(name, opts) do
    key = String.to_atom(name <> "_path")

    case Keyword.get(opts, key) do
      nil ->
        local = Path.join(@pi_bin, name)
        if File.exists?(local), do: local, else: name

      path ->
        path
    end
  end
end
