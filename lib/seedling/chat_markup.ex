defmodule Seedling.ChatMarkup do
  @moduledoc "Restricted safe Markdown: escaped text, code fences, headings, bullets, bold, inline code and HTTP(S) links. Raw HTML never executes."
  def render(text) when is_binary(text) do
    {chunks, code, _} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], nil, false}, fn line, {out, code, in_code} ->
        cond do
          String.starts_with?(line, "```") and in_code ->
            {out ++ ["<pre><code>" <> escape(Enum.join(code, "\n")) <> "</code></pre>"], nil,
             false}

          String.starts_with?(line, "```") ->
            {out, [], true}

          in_code ->
            {out, code ++ [line], true}

          true ->
            {out ++ [line(line)], nil, false}
        end
      end)

    chunks =
      if code,
        do: chunks ++ ["<pre><code>" <> escape(Enum.join(code, "\n")) <> "</code></pre>"],
        else: chunks

    Phoenix.HTML.raw(Enum.join(chunks, "\n"))
  end

  defp line(""), do: "<br>"
  defp line("### " <> s), do: "<h4>" <> inline(s) <> "</h4>"
  defp line("## " <> s), do: "<h3>" <> inline(s) <> "</h3>"
  defp line("# " <> s), do: "<h2>" <> inline(s) <> "</h2>"
  defp line("- " <> s), do: "<p>• " <> inline(s) <> "</p>"
  defp line(s), do: "<p>" <> inline(s) <> "</p>"

  defp inline(s) do
    pattern = ~r/`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\(https?:\/\/[^\s)]+\)/u

    {out, position} =
      Regex.scan(pattern, s, return: :index)
      |> Enum.reduce({[], 0}, fn [{start, size}], {out, position} ->
        token = binary_part(s, start, size)
        {out ++ [escape(binary_part(s, position, start - position)), token(token)], start + size}
      end)

    Enum.join(out ++ [escape(binary_part(s, position, byte_size(s) - position))])
  end

  defp token("`" <> rest),
    do: "<code>" <> escape(String.slice(rest, 0, String.length(rest) - 1)) <> "</code>"

  defp token("**" <> rest),
    do: "<strong>" <> escape(String.slice(rest, 0, String.length(rest) - 2)) <> "</strong>"

  defp token(s) do
    [_, label, url] = Regex.run(~r/^\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)$/u, s)

    "<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"" <>
      escape(url) <> "\">" <> escape(label) <> "</a>"
  end

  defp escape(s), do: Phoenix.HTML.html_escape(s) |> Phoenix.HTML.safe_to_string()
end
