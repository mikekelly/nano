defmodule WebAccess.HTML do
  @moduledoc false
  # A dependency-free, deliberately conservative reader, not an HTML parser.
  def extract(html, url) do
    title =
      case Regex.run(~r/<title\b[^>]*>(.*?)<\/title\s*>/is, html) do
        [_, title] -> plain(title)
        _ -> url
      end

    clean =
      html
      |> replace(~r/<!--.*?-->/s, "")
      |> replace(~r/<(script|style|noscript|svg|nav|footer|aside|form)\b[^>]*>.*?<\/\1\s*>/is, "")
      |> replace(~r/<head\b[^>]*>.*?<\/head\s*>/is, "")

    main =
      case Regex.run(~r/<(?:main|article)\b[^>]*>(.*?)<\/(?:main|article)\s*>/is, clean) do
        [_, body] -> body
        _ -> clean
      end

    text =
      main
      |> replace(~r/<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a\s*>/is, fn _,
                                                                                   href,
                                                                                   label ->
        link(url, href, label)
      end)
      |> replace(~r/<h([1-6])\b[^>]*>/i, fn _, n ->
        "\n\n" <> String.duplicate("#", String.to_integer(n)) <> " "
      end)
      |> replace(~r/<li\b[^>]*>/i, "\n- ")
      |> replace(~r/<(?:br|hr)\b[^>]*\/?\s*>/i, "\n")
      |> replace(
        ~r/<\/(?:p|div|section|article|main|h[1-6]|ul|ol|tr|pre|blockquote)\s*>/i,
        "\n\n"
      )
      |> replace(~r/<\/t[dh]\s*>/i, " | ")
      |> replace(~r/<[^>]+>/s, "")
      |> entities()
      |> replace(~r/[\t \r]+/, " ")
      |> replace(~r/ *\n */, "\n")
      |> replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    %{title: title, text: text}
  end

  defp link(url, href, label) do
    target = URI.merge(url, entities(href)) |> URI.to_string()

    if URI.parse(target).scheme in ["http", "https"],
      do: "[#{plain(label)}](#{target})",
      else: plain(label)
  rescue
    _ -> plain(label)
  end

  defp plain(text), do: text |> replace(~r/<[^>]+>/s, "") |> entities() |> String.trim()
  defp replace(text, regex, replacement), do: Regex.replace(regex, text, replacement)

  defp entities(text) do
    replace(
      text,
      ~r/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp|mdash|ndash|hellip|copy);/,
      fn full, entity ->
        case entity do
          "#x" <> hex ->
            codepoint(hex, 16, full)

          "#" <> dec ->
            codepoint(dec, 10, full)

          name ->
            Map.fetch!(
              %{
                "amp" => "&",
                "lt" => "<",
                "gt" => ">",
                "quot" => "\"",
                "apos" => "'",
                "nbsp" => " ",
                "mdash" => "—",
                "ndash" => "–",
                "hellip" => "…",
                "copy" => "©"
              },
              name
            )
        end
      end
    )
  end

  defp codepoint(value, base, fallback) do
    case Integer.parse(value, base) do
      {n, ""} when n in 1..0x10FFFF and n not in 0xD800..0xDFFF -> <<n::utf8>>
      _ -> fallback
    end
  end
end
