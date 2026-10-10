defmodule Nano.Web.Extract do
  @moduledoc false
  def html(raw, url) do
    title =
      case Regex.run(~r/<title\b[^>]*>(.*?)<\/title>/is, raw) do
        [_, text] -> plain(text)
        _ -> url
      end

    clean =
      Regex.replace(
        ~r/<(script|style|noscript|svg|nav|footer|header)\b[^>]*>.*?<\/\1\s*>/is,
        raw,
        ""
      )

    clean = Regex.replace(~r/<!--.*?-->/s, clean, "")

    content =
      case Regex.run(~r/<(article|main)\b[^>]*>(.*?)<\/\1\s*>/is, clean) do
        [_, _, text] ->
          text

        _ ->
          case Regex.run(~r/<body\b[^>]*>(.*?)<\/body\s*>/is, clean) do
            [_, text] -> text
            _ -> clean
          end
      end

    text =
      Regex.replace(~r/<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a\s*>/is, content, fn _,
                                                                                               href,
                                                                                               label ->
        target = URI.merge(url, decode(href)) |> to_string()

        if URI.parse(target).scheme in ["http", "https"],
          do: "[#{plain(label)}](#{target})",
          else: plain(label)
      end)

    text =
      Regex.replace(~r/<h([1-6])\b[^>]*>(.*?)<\/h\1\s*>/is, text, fn _, n, body ->
        "\n\n#{String.duplicate("#", String.to_integer(n))} #{plain(body)}\n\n"
      end)

    text = Regex.replace(~r/<li\b[^>]*>/i, text, "\n- ")

    text =
      Regex.replace(
        ~r/<\/?(?:p|div|section|article|main|ul|ol|pre|blockquote|table|tr)\b[^>]*>/i,
        text,
        "\n\n"
      )

    text = Regex.replace(~r/<br\b[^>]*>/i, text, "\n")

    {String.slice(title, 0, 300),
     plain(text)
     |> String.replace(~r/[ \t]+/, " ")
     |> String.replace(~r/ *\n */, "\n")
     |> String.replace(~r/\n{3,}/, "\n\n")
     |> String.trim()}
  end

  def markdown_title(text, fallback) do
    case Regex.run(~r/^#\s+(.+)$/m, text) do
      [_, title] -> String.slice(title, 0, 300)
      _ -> fallback
    end
  end

  defp plain(text), do: Regex.replace(~r/<[^>]*>/s, text, "") |> decode() |> String.trim()

  defp decode(text) do
    text =
      Regex.replace(~r/&#(x[0-9a-f]+|[0-9]+);/i, text, fn full, n ->
        try do
          value =
            if String.starts_with?(String.downcase(n), "x"),
              do: String.to_integer(String.slice(n, 1..-1//1), 16),
              else: String.to_integer(n)

          if value in 0..0x10FFFF and value not in 0xD800..0xDFFF, do: <<value::utf8>>, else: full
        rescue
          _ -> full
        end
      end)

    Enum.reduce(
      [
        {"&nbsp;", " "},
        {"&lt;", "<"},
        {"&gt;", ">"},
        {"&quot;", "\""},
        {"&apos;", "'"},
        {"&amp;", "&"}
      ],
      text,
      fn {a, b}, acc -> String.replace(acc, a, b) end
    )
  end
end
