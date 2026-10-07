defmodule Nano.Web.Extract do
  @moduledoc """
  Turn a fetched body into readable text, without a browser when it is not needed. Three paths,
  tried in that order by `readable/2` in `Nano.Web`:

    1. `html/2` — strip scripts, styles, nav and boilerplate, keep headings, paragraphs, lists and
       links, and return **Markdown** (headings, bullets, `[text](url)`), which reads well and is
       what a model wants. Implemented with `Nano.Web.Extract.Script` (a small Node script using
       `html2text`, installed in the container) when Node is present, and with a built-in Elixir
       fallback when it is not.
    2. `pdf/1` — `pdftotext`, paged.
    3. `Nano.Web.lightpanda/2` — the image's headless browser, for pages that need JavaScript.

  Everything returns `{text, meta}` or `{:error, reason}`, never raises, and `Nano.Web` bounds the
  result; this module only converts.
  """

  @doc "True when the body looks like HTML."
  def html?(body), do: is_binary(body) and (String.contains?(body, "<html") or String.contains?(body, "<!DOCTYPE") or String.contains?(body, "<div") or String.contains?(body, "<p>"))

  @doc "True when the body begins like a PDF."
  def pdf?(body), do: is_binary(body) and binary_part(body, 0, min(5, byte_size(body))) == "%PDF-"

  @doc """
  HTML to Markdown. Uses the Node extractor (`priv/web/extract.js`, `html2text` + `jsdom`) when
  Node is available, and the built-in Elixir fallback otherwise. `{:ok, markdown}` or
  `{:error, reason}`.
  """
  def html(body, opts \\ []) do
    case node_extract(body, opts) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:ok, elixir_html(body)}
    end
  end

  # Feed the body to the Node extractor as a file, never on stdin: a Node process reading piped
  # stdin blocks under the eval's group leader, which never EOFs (paid for once in this node's
  # history; see /app/notes/lessons.md).
  defp node_extract(body, _opts) do
    script = Path.join([Nano.Util.app_dir(), "priv", "web", "extract.js"])

    with true <- File.exists?(script),
         node when is_binary(node) <- System.find_executable("node") do
      path = Path.join(System.tmp_dir!(), "nano-web-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".html")
      File.write!(path, body)

      try do
        case Nano.Util.sh("#{node} #{Nano.Util.shell_quote(script)} #{Nano.Util.shell_quote(path)}", timeout: 30_000) do
          %{status: 0, out: out} when out != "" -> {:ok, out}
          %{status: 0} -> {:error, :empty}
          other -> {:error, {:node, other.status, String.slice(other.out, 0, 200)}}
        end
      after
        File.rm(path)
      end
    else
      _ -> {:error, :no_node}
    end
  end

  @doc """
  The built-in fallback: a small, deliberately simple HTML-to-text pass. It removes `script`,
  `style`, `head`, `nav`, `footer`, `noscript` and `svg` blocks, turns block tags into newlines,
  `li` into bullets, `h1..h6` into hashes, and decodes the common entities. No dependency, no
  browser; used when Node is missing.
  """
  def elixir_html(body) do
    body
    |> String.replace(~r/<script\b.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b.*?<\/style>/is, " ")
    |> String.replace(~r/<(head|nav|footer|noscript|svg|template)\b.*?<\/\1>/is, " ")
    |> String.replace(~r/<!--.*?-->/s, " ")
    |> headings()
    |> String.replace(~r/<li[^>]*>/i, "\n- ")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(p|div|section|article|tr|ul|ol|blockquote|pre|h[1-6])>/i, "\n\n")
    |> String.replace(~r/<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is, "\\2 (\\1)")
    |> String.replace(~r/<img\b[^>]*alt=["']([^"']*)["'][^>]*>/i, "[image: \\1]")
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_entities()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n\s*\n+/, "\n\n")
    |> String.trim()
  end

  # `<h2>Title</h2>` -> a Markdown heading of the right depth: one pass per level, because Elixir
  # regex replacements have no backreference.
  defp headings(text) do
    Enum.reduce(1..6, text, fn level, acc ->
      Regex.replace(
        ~r/<h" <> Integer.to_string(level) <> "[^>]*>(.*?)<\/h" <> Integer.to_string(level) <> ">/is,
        acc,
        "\n\n" <> String.duplicate("#", level) <> " \\1\n"
      )
    end)
  end

  @entities %{
    "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'", "&apos;" => "'",
    "&nbsp;" => " ", "&mdash;" => "—", "&ndash;" => "–", "&hellip;" => "…", "&rsquo;" => "’",
    "&lsquo;" => "‘", "&ldquo;" => "“", "&rdquo;" => "”", "&copy;" => "©", "&middot;" => "·"
  }

  @doc "Decodes the common HTML entities and numeric references."
  def decode_entities(text) do
    text = Enum.reduce(@entities, text, fn {k, v}, acc -> String.replace(acc, k, v) end)

    Regex.replace(~r/&#x([0-9a-fA-F]+);/, text, fn _, hex -> <<String.to_integer(hex, 16)::utf8>> end)
    |> then(fn t -> Regex.replace(~r/&#(\d+);/, t, fn _, dec -> <<String.to_integer(dec)::utf8>> end) end)
  end

  @doc "PDF bytes to text via `pdftotext` (`{:ok, text}` or `{:error, reason}`)."
  def pdf(body) do
    with bin when is_binary(bin) <- System.find_executable("pdftotext") do
      path = Path.join(System.tmp_dir!(), "nano-web-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".pdf")
      out = path <> ".txt"
      File.write!(path, body)

      try do
        case Nano.Util.sh("#{bin} -layout -enc UTF-8 #{Nano.Util.shell_quote(path)} #{Nano.Util.shell_quote(out)}", timeout: 60_000) do
          %{status: 0} ->
            case File.read(out) do
              {:ok, text} -> {:ok, text}
              {:error, r} -> {:error, r}
            end

          other -> {:error, {:pdftotext, other.status}}
        end
      after
        File.rm(path)
        File.rm(out)
      end
    else
      _ -> {:error, :no_pdftotext}
    end
  end
end
