defmodule NanoWeb.BotsMarkdown do
  @moduledoc """
  A deliberately small, safe Markdown renderer for untrusted bot messages.

  Use directly in HEEx: `{NanoWeb.BotsMarkdown.render(message)}`. The result
  is Phoenix HTML safe iodata, built only from fixed tags and escaped text.
  Raw HTML, including HTML entities, is always displayed as text, never trusted.

  Supported subset:

    * Paragraphs (soft line breaks), ATX headings `#` through `######`.
    * Flat, single-line unordered (`-`, `+`, `*`) and ordered (`1.`) lists.
      Ordered lists always start at one; nesting and continuation are not parsed.
    * Backtick or tilde fences of at least three characters. A closing fence
      must use the same character and be at least as long. Info strings are
      ignored; code is escaped, with no syntax highlighting. Unclosed fences
      extend to the end of the bounded input.
    * Single-backtick inline code, `*emphasis*` / `_emphasis_`, and
      `**strong**` / `__strong__`, with nonempty, single-line contents.
    * `[plain label](absolute-url)` links, only for literal HTTP(S) schemes
      with a host, no credentials, whitespace, controls or backslashes.
      Labels are plain text. Rejected links remain visible as literal Markdown.

  This is not CommonMark. Inline constructs do not nest. Images, reference
  links, autolinks, tables, blockquotes, backslash escapes and HTML are not
  interpreted. Inline contents and URLs are limited to 2,048 characters and
  link labels to 512 characters. All regex repetitions that search for an
  inline closing delimiter are bounded; parsing never recursively expands text.

  At most the first 65,536 input bytes are processed, followed by a visible
  truncation notice when needed. Invalid UTF-8 (including a split final
  character) becomes the replacement character. CRLF and CR become newlines.
  `nil` and other non-binary values render as empty content; in particular,
  callers cannot pass a `{:safe, ...}` tuple through this trust boundary.
  """

  @max_bytes 65_536
  @fence_open ~r/\A {0,3}(`{3,}|~{3,})(.*)\z/u
  @fence_close ~r/\A {0,3}(`{3,}|~{3,})[ \t]*\z/u
  @heading ~r/\A {0,3}(\#{1,6})(?:[ \t]+(.*)|\z)/u
  @unordered ~r/\A {0,3}[-+*][ \t]+(.*)\z/u
  @ordered ~r/\A {0,3}[0-9]{1,9}\.[ \t]+(.*)\z/u
  @inline ~r/(`[^`\n]{1,2048}`|!?\[[^\[\]\n]{1,512}\]\([^\s()]{1,2048}\)|\*\*[^*\n]{1,2048}\*\*|__[^_\n]{1,2048}__|\*[^*\n]{1,2048}\*|_[^_\n]{1,2048}_)/u
  @link ~r/\A\[([^\[\]\n]{1,512})\]\(([^\s()]{1,2048})\)\z/u
  @url_scheme ~r/\Ahttps?:\/\//i
  @unsafe_url_character ~r/[\p{Z}\p{C}\\<>"`]/u

  @doc "Renders the bounded Markdown subset as Phoenix HTML safe iodata."
  @spec render(term()) :: Phoenix.HTML.safe()
  def render(text) when is_binary(text) do
    truncated? = byte_size(text) > @max_bytes

    text =
      text
      |> binary_part(0, min(byte_size(text), @max_bytes))
      |> String.replace_invalid()
      |> String.replace(["\r\n", "\r"], "\n")

    # The final split element represents a line terminator, not an extra code line.
    lines = String.split(text, "\n")
    lines = if String.ends_with?(text, "\n"), do: Enum.drop(lines, -1), else: lines

    notice = if truncated?, do: "<p>[Markdown truncated at 65,536 bytes.]</p>", else: []
    {:safe, [blocks(lines), notice]}
  end

  def render(_), do: {:safe, []}

  defp blocks([]), do: []

  defp blocks([line | rest] = lines) do
    case block_kind(line) do
      :blank ->
        blocks(rest)

      {:fence, marker} ->
        {body, remaining} = Enum.split_while(rest, &(not closes_fence?(&1, marker)))
        remaining = if remaining == [], do: [], else: tl(remaining)
        code = Enum.map(body, &[escape(&1), "\n"])
        ["<pre><code>", code, "</code></pre>", blocks(remaining)]

      {:heading, level, content} ->
        tag = "h" <> Integer.to_string(level)
        [element(tag, inline(content)), blocks(rest)]

      {type, _content} when type in [:ul, :ol] ->
        {items, remaining} = Enum.split_while(lines, &list_item?(&1, type))

        items =
          Enum.map(items, fn item ->
            {^type, content} = block_kind(item)
            element("li", inline(content))
          end)

        [element(Atom.to_string(type), items), blocks(remaining)]

      :paragraph ->
        {paragraph, remaining} = Enum.split_while(lines, &(block_kind(&1) == :paragraph))
        content = paragraph |> Enum.map(&inline/1) |> Enum.intersperse("\n")
        [element("p", content), blocks(remaining)]
    end
  end

  defp block_kind(line) do
    cond do
      String.trim(line) == "" ->
        :blank

      match = Regex.run(@fence_open, line) ->
        [_, marker, _info] = match
        {:fence, marker}

      match = Regex.run(@heading, line) ->
        [_, marker | content] = match
        {:heading, byte_size(marker), List.first(content) || ""}

      match = Regex.run(@unordered, line) ->
        [_, content] = match
        {:ul, content}

      match = Regex.run(@ordered, line) ->
        [_, content] = match
        {:ol, content}

      true ->
        :paragraph
    end
  end

  defp list_item?(line, type) do
    case block_kind(line) do
      {^type, _} -> true
      _ -> false
    end
  end

  defp closes_fence?(line, opening) do
    case Regex.run(@fence_close, line) do
      [_, closing] ->
        binary_part(closing, 0, 1) == binary_part(opening, 0, 1) and
          byte_size(closing) >= byte_size(opening)

      _ ->
        false
    end
  end

  defp inline(text) do
    @inline
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.map(fn {token, index} ->
      if rem(index, 2) == 1, do: inline_token(token), else: escape(token)
    end)
  end

  defp inline_token("`" <> _ = token), do: wrapped_token(token, "`", "code")
  defp inline_token("**" <> _ = token), do: wrapped_token(token, "**", "strong")
  defp inline_token("__" <> _ = token), do: wrapped_token(token, "__", "strong")
  defp inline_token("*" <> _ = token), do: wrapped_token(token, "*", "em")
  defp inline_token("_" <> _ = token), do: wrapped_token(token, "_", "em")

  defp inline_token("[" <> _ = token) do
    case Regex.run(@link, token) do
      [_, label, url] ->
        if safe_url?(url) do
          [
            "<a href=\"",
            escape(url),
            "\" rel=\"nofollow noopener noreferrer\">",
            escape(label),
            "</a>"
          ]
        else
          escape(token)
        end

      _ ->
        escape(token)
    end
  end

  defp inline_token(token), do: escape(token)

  defp wrapped_token(token, marker, tag) do
    size = byte_size(marker)
    content_size = byte_size(token) - 2 * size
    element(tag, escape(binary_part(token, size, content_size)))
  end

  defp safe_url?(url) do
    if Regex.match?(@url_scheme, url) and not Regex.match?(@unsafe_url_character, url) do
      case URI.new(url) do
        {:ok, %URI{host: host, userinfo: nil}} when is_binary(host) and host != "" -> true
        _ -> false
      end
    else
      false
    end
  end

  defp element(tag, content), do: ["<", tag, ">", content, "</", tag, ">"]

  defp escape(text) do
    {:safe, escaped} = Phoenix.HTML.html_escape(text)
    escaped
  end
end
