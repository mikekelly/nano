defmodule Vega.Bots.Markdown do
  @moduledoc """
  Small Markdown subset for untrusted bot output: paragraphs, flat lists,
  emphasis, code and absolute HTTP(S) links. HTML and images remain text.
  """
  @spec render(binary() | nil) :: Phoenix.HTML.safe()
  def render(nil), do: {:safe, []}

  def render(text) when is_binary(text) do
    {:safe,
     blocks(
       text
       |> String.replace("\r\n", "\n")
       |> String.replace("\r", "\n")
       |> String.split("\n")
     )}
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  defp blocks([]), do: []

  defp blocks([line | rest] = lines) do
    cond do
      String.trim(line) == "" ->
        blocks(rest)

      Regex.match?(~r/^\s{0,3}```/, line) ->
        {code, tail} = Enum.split_while(rest, &(not Regex.match?(~r/^\s{0,3}```\s*$/, &1)))

        tail =
          case tail do
            [] -> []
            [_ | remaining] -> remaining
          end

        ["<pre><code>", escape(Enum.join(code, "\n")), "</code></pre>" | blocks(tail)]

      list_kind(line) != nil ->
        kind = list_kind(line)
        {items, tail} = Enum.split_while(lines, &(list_kind(&1) == kind))
        tag = if kind == :ordered, do: "ol", else: "ul"

        [
          "<",
          tag,
          ">",
          Enum.map(items, fn item ->
            body = Regex.replace(~r/^\s{0,3}(?:[-+*]|\d+\.)\s+/, item, "")
            ["<li>", inline(body), "</li>"]
          end),
          "</",
          tag,
          ">" | blocks(tail)
        ]

      true ->
        {paragraph, tail} =
          Enum.split_while(lines, fn item ->
            String.trim(item) != "" and list_kind(item) == nil and
              not Regex.match?(~r/^\s{0,3}```/, item)
          end)

        ["<p>", inline(Enum.join(paragraph, "\n")), "</p>" | blocks(tail)]
    end
  end

  defp list_kind(line) do
    cond do
      Regex.match?(~r/^\s{0,3}[-+*]\s+/, line) -> :unordered
      Regex.match?(~r/^\s{0,3}\d+\.\s+/, line) -> :ordered
      true -> nil
    end
  end

  # Tokens are recognized before escaping; generated markup is never parsed again.
  @tokens ~r/`[^`\n]+`|!?\[[^\]\n]*\]\([^\)\n]*\)|\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|_[^_\n]+_/
  defp inline(text, depth \\ 0)
  defp inline(text, depth) when depth >= 8, do: escape(text)

  defp inline(text, depth) do
    case Regex.run(@tokens, text, return: :index) do
      nil ->
        escape(text)

      [{start, length}] ->
        prefix = binary_part(text, 0, start)
        token = binary_part(text, start, length)
        suffix = binary_part(text, start + length, byte_size(text) - start - length)
        [escape(prefix), token(token, depth), inline(suffix, depth)]
    end
  end

  defp token("`" <> rest, _), do: ["<code>", escape(String.slice(rest, 0..-2//1)), "</code>"]
  defp token("![" <> _ = text, _), do: escape(text)

  defp token("[" <> _ = text, depth) do
    [_, label, url] = Regex.run(~r/^\[([^\]]*)\]\((.*)\)$/s, text)

    if safe_url?(url) do
      [
        "<a href=\"",
        escape(url),
        "\" rel=\"noopener noreferrer\">",
        inline(label, depth + 1),
        "</a>"
      ]
    else
      escape(text)
    end
  end

  defp token(text, depth) do
    strong = String.starts_with?(text, ["**", "__"])
    width = if strong, do: 2, else: 1
    tag = if strong, do: "strong", else: "em"
    body = binary_part(text, width, byte_size(text) - width * 2)
    ["<", tag, ">", inline(body, depth + 1), "</", tag, ">"]
  end

  defp safe_url?(url) do
    # Reject browser normalization ambiguities, controls and credentials.
    if Regex.match?(~r/[\s\x00-\x1f\x7f\\<>"']/, url) do
      false
    else
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} ->
          scheme in ["http", "https"] and is_binary(host) and host != "" and
            String.starts_with?(url, ["http://", "https://"])

        _ ->
          false
      end
    end
  end
end
