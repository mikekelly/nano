defmodule Seedling.Web.Readability do
  @moduledoc false
  alias Seedling.Web.Store

  def extract(html, url) do
    title = capture(html, ~r/<title\b[^>]*>(.*?)<\/title\s*>/is) |> plain() |> Store.clip(300)

    clean =
      Regex.replace(
        ~r/<!--.*?-->|<(script|style|noscript|svg|iframe|nav|footer|header|form)\b[^>]*>.*?<\/\1\s*>/is,
        html,
        ""
      )

    article =
      Regex.scan(~r/<article\b[^>]*>(.*?)<\/article\s*>/is, clean)
      |> Enum.map(&List.last/1)
      |> Enum.join("\n\n")

    main = capture(clean, ~r/<main\b[^>]*>(.*?)<\/main\s*>/is)
    body = capture(clean, ~r/<body\b[^>]*>(.*?)<\/body\s*>/is)
    chosen = Enum.find([main, article, body, clean], &(String.length(plain(&1)) > 80)) || clean
    text = markdown(chosen, url)

    shell =
      String.length(text) < 160 or
        Regex.match?(~r/(enable|requires?) javascript|loading\.\.\.|checking your browser/i, text)

    %{title: title, text: text, shell: shell}
  end

  defp markdown(html, url) do
    html =
      Regex.replace(~r/<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a\s*>/is, html, fn _,
                                                                                            href,
                                                                                            label ->
        link =
          try do
            URI.merge(url, entities(href)) |> URI.to_string()
          rescue
            _ -> ""
          end

        label = plain(label)

        if URI.parse(link).scheme in ["http", "https"] and label != "",
          do: "[#{label}](#{link})",
          else: label
      end)

    html =
      Regex.replace(~r/<h([1-6])\b[^>]*>(.*?)<\/h\1\s*>/is, html, fn _, n, text ->
        "\n\n#{String.duplicate("#", String.to_integer(n))} #{plain(text)}\n\n"
      end)

    html = Regex.replace(~r/<li\b[^>]*>/i, html, "\n- ")

    html =
      Regex.replace(
        ~r/<(?:br|hr)\b[^>]*>|<\/?(?:p|div|section|article|main|ul|ol|table|tr|blockquote|pre)\b[^>]*>/i,
        html,
        "\n\n"
      )

    html
    |> plain_keep_lines()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/ *\n */, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp capture(text, regex) do
    case Regex.run(regex, text) do
      [_, captured] -> captured
      _ -> ""
    end
  end

  defp plain(html),
    do: html |> plain_keep_lines() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp plain_keep_lines(html), do: html |> String.replace(~r/<[^>]+>/s, "") |> entities()

  defp entities(text) do
    text =
      Regex.replace(~r/&#(x[0-9a-f]+|[0-9]+);/i, text, fn full, value ->
        try do
          code =
            if String.starts_with?(String.downcase(value), "x"),
              do: String.to_integer(String.slice(value, 1..-1//1), 16),
              else: String.to_integer(value)

          <<code::utf8>>
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
      fn {from, to}, acc -> String.replace(acc, from, to) end
    )
  end
end
