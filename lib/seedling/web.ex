defmodule Seedling.Web do
  @moduledoc """
  HTTP-first web reading with bounded, disk-cached pages and checkable passages.

      {:ok, page} = Seedling.Web.fetch("https://elixir-lang.org")
      Seedling.Web.read(page.id, offset: page.next_offset)
      Seedling.Web.cite(page.id, offset: 0, limit: 400)

  `mode: :auto` (default) tries HTTP extraction and falls back to Lightpanda for
  probable JavaScript shells. Force `:browser` for dynamic pages or `:http` to avoid
  a browser. All public operations return values, not HTTP exceptions. Pages default
  to 6,000 characters / 12,000 bytes. Cache: one hour, 100 entries under
  `/data/orion-web/cache`; override `:cache_dir`, `:ttl`, `:cache_entries` per call.
  Page offsets are zero-based Unicode grapheme counts, not bytes or lines.
  See `docs/web-search.md` for extraction limits, untrusted web content and research.
  """
  alias Seedling.Web.{Store, Transport}

  def fetch(url, opts \\ []) do
    with :ok <- Transport.url(url),
         mode when mode in [:auto, :http, :browser] <- Keyword.get(opts, :mode, :auto) do
      key = url <> ":" <> Atom.to_string(mode)

      case if(Keyword.get(opts, :refresh, false),
             do: {:error, :refresh},
             else: Store.get(Store.id(key), opts)
           ) do
        {:ok, rec} ->
          with {:ok, page} <- Store.page(rec, opts), do: {:ok, Map.put(page, :cached, true)}

        _ ->
          started = System.monotonic_time(:millisecond)

          with {:ok, doc} <- obtain(url, mode, opts),
               true <- String.valid?(doc.text),
               {:ok, rec} <-
                 Store.put(
                   key,
                   doc.text,
                   %{
                     "url" => doc.url,
                     "title" => doc.title,
                     "source" => doc.source,
                     "content_truncated" => doc.content_truncated
                   },
                   opts
                 ),
               {:ok, page} <- Store.page(rec, opts) do
            {:ok,
             Map.merge(page, %{
               cached: false,
               elapsed_ms: System.monotonic_time(:millisecond) - started
             })}
          else
            false -> {:error, %{kind: :encoding, hint: "Only UTF-8 text is currently supported"}}
            error -> error
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, %{kind: :invalid_mode}}
    end
  end

  def read(id, opts \\ []) do
    with {:ok, rec} <- Store.get(id, opts), do: Store.page(rec, opts)
  end

  @doc "Quote an exact stored passage with source URL, retrieval time and stable cache offsets."
  def cite(id, opts \\ []) do
    with {:ok, page} <- read(id, Keyword.put_new(opts, :limit, 800)) do
      {:ok,
       %{
         url: page.url,
         title: page.title,
         fetched_at: page.fetched_at,
         id: id,
         offset: page.offset,
         end_offset: page.offset + String.length(page.text),
         quote: page.text
       }}
    end
  end

  @doc "Gather passages from explicit URLs; does not adjudicate whether the claim is true."
  def evidence(claim, urls, opts \\ []) when is_binary(claim) and is_list(urls) do
    if length(urls) <= 10 do
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 20000)

      results =
        Task.async_stream(
          urls,
          fn url ->
            remaining = deadline - System.monotonic_time(:millisecond)

            if remaining > 0 do
              with {:ok, page} <- fetch(url, Keyword.put(opts, :timeout, remaining)),
                   do:
                     cite(
                       page.id,
                       Keyword.merge(opts,
                         limit: min(Keyword.get(opts, :limit, 800), 800),
                         max_bytes: 1600
                       )
                     )
            else
              {:error, %{kind: :timeout}}
            end
          end,
          max_concurrency: 3,
          timeout: Keyword.get(opts, :timeout, 20000) + 2000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          _ -> {:error, %{kind: :timeout}}
        end)

      {:ok,
       %{
         claim: Store.clip(claim, 1000),
         passages: results,
         note: "Passages are evidence candidates, not a verdict"
       }}
    else
      {:error, %{kind: :too_many_urls, max: 10}}
    end
  end

  defp obtain(url, :browser, opts), do: Seedling.Browser.fetch(url, opts)

  defp obtain(url, mode, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 20000)

    case http(url, opts) do
      {:ok, %{shell: true}} when mode == :auto ->
        remaining = max(1, deadline - System.monotonic_time(:millisecond))

        case Seedling.Browser.fetch(url, Keyword.put(opts, :timeout, remaining)) do
          {:ok, doc} ->
            {:ok, doc}

          {:error, error} ->
            {:error,
             %{
               kind: :javascript_required,
               browser_error: error,
               hint: "HTTP returned a probable JavaScript shell"
             }}
        end

      {:ok, %{shell: true}} ->
        {:error, %{kind: :javascript_required, hint: "Retry with mode: :browser"}}

      result ->
        result
    end
  end

  defp http(url, opts) do
    with {:ok, response} <- Transport.request(:get, url, nil, opts) do
      type =
        response.headers |> Map.get("content-type", [""]) |> List.first() |> String.downcase()

      cond do
        response.status not in 200..299 ->
          {:error, %{kind: :http, status: response.status}}

        not String.valid?(response.body) ->
          {:error, %{kind: :unsupported_content, content_type: type}}

        String.starts_with?(type, "text/html") or String.starts_with?(type, "application/xhtml") ->
          {title, text} = extract(response.body, url)

          shell =
            String.length(text) < Keyword.get(opts, :shell_threshold, 160) and
              Regex.match?(~r/<script\b|id=["'](?:root|app|__next)["']/i, response.body)

          {:ok,
           %{
             title: title,
             text: text,
             url: url,
             source: "http",
             shell: shell,
             content_truncated: false
           }}

        String.starts_with?(type, "text/") or String.starts_with?(type, "application/json") ->
          {:ok,
           %{
             title: nil,
             text: response.body,
             url: url,
             source: "http",
             shell: false,
             content_truncated: false
           }}

        true ->
          {:error,
           %{
             kind: :unsupported_content,
             content_type: type,
             hint:
               "PDFs, repositories and video need dedicated tools; use a raw text URL when available"
           }}
      end
    end
  end

  @doc false
  def extract(html, url) do
    title =
      case Regex.run(~r/<title\b[^>]*>(.*?)<\/title>/is, html, capture: :all_but_first) do
        [text] -> entities(String.trim(text))
        _ -> nil
      end

    clean =
      html
      |> then(&Regex.replace(~r/<!--.*?-->/s, &1, ""))
      |> then(
        &Regex.replace(
          ~r/<(script|style|noscript|svg|nav|footer|aside)\b[^>]*>.*?<\/\1\s*>/is,
          &1,
          ""
        )
      )

    main =
      case Regex.run(~r/<main\b[^>]*>(.*)<\/main>/is, clean, capture: :all_but_first) do
        [text] ->
          text

        _ ->
          case Regex.run(~r/<article\b[^>]*>(.*)<\/article>/is, clean, capture: :all_but_first) do
            [text] -> text
            _ -> clean
          end
      end

    text =
      main
      |> then(
        &Regex.replace(~r/<a\b[^>]*\bhref\s*=\s*["']([^"']*)["'][^>]*>(.*?)<\/a>/is, &1, fn _,
                                                                                            href,
                                                                                            body ->
          label = Regex.replace(~r/<[^>]*>/s, body, "") |> entities() |> String.trim()

          link =
            try do
              URI.merge(url, entities(href)) |> URI.to_string()
            rescue
              _ -> ""
            end

          if Transport.url(link) == :ok, do: "[#{label}](#{link})", else: label
        end)
      )
      |> then(
        &Regex.replace(~r/<h([1-6])\b[^>]*>/i, &1, fn _, n ->
          "\n\n" <> String.duplicate("#", String.to_integer(n)) <> " "
        end)
      )
      |> then(
        &Regex.replace(
          ~r/<(?:br|\/p|\/div|\/h[1-6]|\/li|\/tr|\/section|\/pre)\b[^>]*>/i,
          &1,
          "\n"
        )
      )
      |> then(&Regex.replace(~r/<li\b[^>]*>/i, &1, "\n- "))
      |> then(&Regex.replace(~r/<[^>]*>/s, &1, ""))
      |> entities()
      |> then(&Regex.replace(~r/[\t\x20]+/, &1, " "))
      |> then(&Regex.replace(~r/\n\s*\n\s*\n/, &1, "\n\n"))
      |> String.trim()

    {title, text}
  end

  defp entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/, text, fn entity,
                                                                                    name ->
      case name do
        "amp" -> "&"
        "lt" -> "<"
        "gt" -> ">"
        "quot" -> "\""
        "apos" -> "'"
        "nbsp" -> " "
        "#x" <> hex -> codepoint(hex, 16, entity)
        "#" <> decimal -> codepoint(decimal, 10, entity)
      end
    end)
  end

  defp codepoint(number, base, fallback) do
    case Integer.parse(number, base) do
      {n, ""} when n in 1..0x10FFFF and n not in 0xD800..0xDFFF -> <<n::utf8>>
      _ -> fallback
    end
  end
end
