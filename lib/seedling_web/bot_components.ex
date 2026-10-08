defmodule SeedlingWeb.BotComponents do
  @moduledoc """
  Friendly bot faces and deliberately conservative, safe Markdown rendering.
  No model-generated HTML is trusted. Supported blocks: paragraphs, headings, lists,
  blockquotes and fenced code; inline code/bold/emphasis and HTTPS links. HTML,
  images, javascript/data URLs and raw event handlers render as inert text.
  Files are explicit downloads through the bounded attachment service.
  """
  use Phoenix.Component
  attr :bot, :map, required: true
  attr :small, :boolean, default: false

  def face(assigns) do
    ~H"""
    <span
      class={["bot-face", @small && "small", "shape-#{@bot["shape"]}"]}
      style={"--face-color: #{@bot["color"]}"}
      aria-hidden="true"
    ><span>• •</span><i>⌣</i></span>
    """
  end

  @doc "Escapes input before adding a small allowlist of generated markup."
  def markdown(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> blocks([], [], false)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> Phoenix.HTML.raw()
  end

  defp blocks([], out, code, true),
    do: ["<pre><code>" <> escape(Enum.reverse(code) |> Enum.join("\n")) <> "</code></pre>" | out]

  defp blocks([], out, _, false), do: out

  defp blocks([line | rest], out, code, in_code) do
    cond do
      String.starts_with?(line, "```") and in_code ->
        blocks(
          rest,
          [
            "<pre><code>" <> escape(Enum.reverse(code) |> Enum.join("\n")) <> "</code></pre>"
            | out
          ],
          [],
          false
        )

      String.starts_with?(line, "```") ->
        blocks(rest, out, [], true)

      in_code ->
        blocks(rest, out, [line | code], true)

      String.trim(line) == "" ->
        blocks(rest, out, [], false)

      Regex.match?(~r/^\#{1,3} /, line) ->
        [marks, content] = String.split(line, " ", parts: 2)
        tag = "h#{String.length(marks) + 1}"
        blocks(rest, ["<#{tag}>" <> inline(content) <> "</#{tag}>" | out], [], false)

      String.starts_with?(line, ["- ", "* "]) ->
        blocks(
          rest,
          ["<div class=\"md-list\">• " <> inline(String.slice(line, 2..-1//1)) <> "</div>" | out],
          [],
          false
        )

      String.starts_with?(line, "> ") ->
        blocks(
          rest,
          ["<blockquote>" <> inline(String.slice(line, 2..-1//1)) <> "</blockquote>" | out],
          [],
          false
        )

      true ->
        blocks(rest, ["<p>" <> inline(line) <> "</p>" | out], [], false)
    end
  end

  defp inline(text) do
    # Tokenize before escaping, then handle each token independently. Nested raw HTML
    # never re-enters a parser, and code spans cannot accidentally become links.
    Regex.split(
      ~r/(`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*|\[[^\]\n]+\]\(https:\/\/[^\s)]+\))/,
      text,
      include_captures: true
    )
    |> Enum.map_join(fn token ->
      cond do
        String.starts_with?(token, "`") and String.ends_with?(token, "`") ->
          "<code>" <> escape(String.slice(token, 1..-2//1)) <> "</code>"

        String.starts_with?(token, "**") and String.ends_with?(token, "**") ->
          "<strong>" <> escape(String.slice(token, 2..-3//1)) <> "</strong>"

        String.starts_with?(token, "*") and String.ends_with?(token, "*") ->
          "<em>" <> escape(String.slice(token, 1..-2//1)) <> "</em>"

        Regex.match?(~r/^\[[^\]]+\]\(https:\/\/[^\s)]+\)$/, token) ->
          [_, label, url] = Regex.run(~r/^\[([^\]]+)\]\(([^)]+)\)$/, token)

          "<a href=\"" <>
            escape(url) <>
            "\" target=\"_blank\" rel=\"noopener noreferrer\">" <> escape(label) <> "</a>"

        true ->
          escape(token)
      end
    end)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
