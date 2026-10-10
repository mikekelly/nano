defmodule Nano.Bots.Render do
  @moduledoc """
  Conservative Markdown subset: paragraphs, flat lists, fenced/inline code,
  emphasis and explicit HTTP(S) links. Not CommonMark; no tables, nesting,
  HTML, autolinks or images. Render images separately using validated attachments.
  Raw HTML is text; generated tags are never reparsed and attributes are fixed.
  """
  def markdown(text) when is_binary(text),
    do:
      Phoenix.HTML.raw(
        text
        |> String.split(~r/\r\n|\n|\r/)
        |> blocks([])
        |> IO.iodata_to_binary()
      )

  def markdown(_), do: Phoenix.HTML.raw("")
  defp escape(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | tail], acc) do
    cond do
      String.trim(line) == "" ->
        blocks(tail, acc)

      String.starts_with?(line, "```") ->
        {code, rest} = Enum.split_while(tail, &(not String.starts_with?(&1, "```")))
        rest = if rest == [], do: [], else: tl(rest)
        blocks(rest, ["<pre><code>" <> escape(Enum.join(code, "\n")) <> "</code></pre>" | acc])

      list_line?(line) ->
        ordered = Regex.match?(~r/^\d+\. /, line)
        pattern = if ordered, do: ~r/^\d+\. /, else: ~r/^[-*+] /
        {items, rest} = Enum.split_while([line | tail], &Regex.match?(pattern, &1))
        tag = if ordered, do: "ol", else: "ul"
        body = Enum.map(items, &("<li>" <> inline(Regex.replace(pattern, &1, "")) <> "</li>"))
        blocks(rest, [["<", tag, ">", body, "</", tag, ">"] | acc])

      true ->
        {lines, rest} =
          Enum.split_while(
            [line | tail],
            &(String.trim(&1) != "" and not String.starts_with?(&1, "```") and not list_line?(&1))
          )

        blocks(rest, ["<p>" <> inline(Enum.join(lines, "\n")) <> "</p>" | acc])
    end
  end

  defp list_line?(s), do: Regex.match?(~r/^(?:[-*+] |\d+\. )/, s)
  defp inline(""), do: ""

  defp inline(s) do
    pattern =
      ~r/`([^`\n]+)`|!\[([^\]\n]*)\]\(([^)\n]*)\)|\[([^\]\n]*)\]\(([^)\n]*)\)|\*\*([^*\n]+)\*\*|\*([^*\n]+)\*/

    case Regex.run(pattern, s, return: :index) do
      nil ->
        escape(s)

      [{start, len} | _] ->
        prefix = binary_part(s, 0, start)
        token = binary_part(s, start, len)
        suffix = binary_part(s, start + len, byte_size(s) - start - len)
        escape(prefix) <> token_html(token) <> inline(suffix)
    end
  end

  defp token_html("`" <> token),
    do: "<code>" <> escape(String.slice(token, 0..-2//1)) <> "</code>"

  defp token_html("![" <> _ = token), do: escape(token)

  defp token_html("[" <> _ = token) do
    [_, label, url] = Regex.run(~r/^\[([^\]]*)\]\((.*)\)$/, token)

    if safe_url?(url),
      do:
        "<a href=\"" <>
          escape(url) <> "\" rel=\"nofollow noopener noreferrer\">" <> escape(label) <> "</a>",
      else: escape(token)
  end

  defp token_html("**" <> token),
    do: "<strong>" <> escape(String.slice(token, 0..-3//1)) <> "</strong>"

  defp token_html("*" <> token), do: "<em>" <> escape(String.slice(token, 0..-2//1)) <> "</em>"

  defp safe_url?(url) do
    uri = URI.parse(url)

    not Regex.match?(~r/[\x00-\x20\x7f\\&<>"']/, url) and
      uri.scheme in ["http", "https", "HTTP", "HTTPS"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo)
  rescue
    _ -> false
  end
end
