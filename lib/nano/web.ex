defmodule Nano.Web do
  @moduledoc """
  Read the web: fetch pages as readable text, search, read back stored content, and check a claim
  against sources. The seeding is `/app/seedings/web-access.md`; the reference is pi's
  `pi-web-access`, whose function names are kept where they fit.

      Nano.Web.fetch_content("https://example.com")                 # readable Markdown
      Nano.Web.fetch_content(["https://a.example", "https://b.example"])
      Nano.Web.fetch_content("https://x/y.pdf")                     # PDF -> text, paged
      Nano.Web.fetch_content("https://spa.example", mode: :lightpanda)  # needs JavaScript
      Nano.Web.get_search_content(handle, offset: 0, limit: 4000)   # page through what was fetched
      Nano.Web.get_search_content(handle, search: "cache")          # find in it, with context
      Nano.Web.web_search("OTP 29 release notes", num_results: 5)
      Nano.Web.source_check("Elixir 1.20 supports the type system")

  ## Providers: what is and is not available here

    * **fetch** needs nothing but this node: HTTP first, then readability extraction, then
      `pdftotext` for PDFs, then the image's headless browser (Lightpanda) for JavaScript.
    * **search** uses Exa when `EXA_API_KEY` is set (see `search.md`); without a key it falls back
      to a keyless provider (Wikipedia's API, and DuckDuckGo's HTML endpoint when it is not
      rate-limiting). `providers/0` says which are usable right now, honestly.
    * **video** is not supported: no vision model on this node (the seeding says to skip it).

  ## Bounds, in one place

  `limits/0` holds them. Every fetch is cached for an hour (`cache_ttl`), content is sliced to
  `content_chars` (30,000 by default, as the reference does) and every read by the model goes
  through a paging call, so a page never has to enter context whole. Requests time out at
  `timeout_ms`. `fetch_content` returns a `handle` for the full text as well, so nothing is lost.
  """

  @limits %{
    timeout_ms: 30_000,
    content_chars: 30_000,
    cache_ttl: 3_600_000,
    cache_max: 40,
    search_results: 5,
    search_max: 20,
    page_chars: 4_000,
    max_bytes: 8_000_000
  }

  @doc "The bounds this module applies, as a map."
  def limits, do: @limits

  ## providers

  @doc """
  Which providers are usable on this node right now: `%{fetch: %{http: true, pdf: …, js: …},
  search: [%{id:, available: bool, why: …}]}`. Honest, so a caller never has to guess.
  """
  def providers do
    %{
      fetch: %{
        http: true,
        readability: File.exists?(Path.join([Nano.Util.app_dir(), "priv", "web", "extract.js"])),
        node: System.find_executable("node") != nil,
        pdf: System.find_executable("pdftotext") != nil,
        lightpanda: System.find_executable("lightpanda") != nil,
        video: false
      },
      search: search_providers()
    }
  end

  defp search_providers do
    [
      %{id: :exa, available: present?(System.get_env("EXA_API_KEY")), why: "needs EXA_API_KEY in the environment"},
      %{id: :wikipedia, available: true, why: "keyless; good for reference facts, not for the open web"},
      %{id: :duckduckgo, available: true, why: "keyless HTML endpoint; may rate-limit this node"}
    ]
  end

  defp present?(v), do: v not in [nil, ""]

  ## fetch_content

  @doc """
  Fetches one URL (or a list) and returns readable content. Options:

    * `mode:` — `:markdown` (default, readability extraction), `:raw` (the body as it came)
    * `max:` — how much text to return (default `limits().content_chars`); the rest is kept and
      named by the `handle` in the result, pageable with `get_search_content/2`
    * `prompt:` — return the text, and a `prompt` field for the caller to answer it with (the
      reference has a vision model answer it; there is none here, so the text is returned and the
      question is echoed back with it)
    * `timeout:` — milliseconds (default `limits().timeout_ms`)
    * `refresh:` — bypass the cache

  Returns `{:ok, %{url:, status:, content_type:, text:, chars:, truncated:, handle:, cached:, …}}`
  or `{:error, reason}`. For a list, `{:ok, [result]}`.
  """
  def fetch_content(urls, opts \\ [])

  def fetch_content(urls, opts) when is_list(urls), do: {:ok, Enum.map(urls, &fetch_one(&1, opts))}
  def fetch_content(url, opts), do: fetch_one(url, opts)

  @doc "`fetch_content/2`, dropping the error terms into the result as `%{error: reason}`."
  def fetch!(urls, opts \\ []) do
    case fetch_content(urls, opts) do
      {:ok, result} -> result
      {:error, reason} -> %{error: reason}
    end
  end

  defp fetch_one(url, opts) do
    with {:ok, url} <- normalize_url(url),
         {:ok, body, meta} <- cached_fetch(url, opts) do
      {text, kind} = to_text(body, url, meta, opts)
      text = text || ""
      max = Keyword.get(opts, :max, @limits.content_chars)
      handle = store(url, text)

      %{
        url: url,
        final_url: meta[:final_url],
        status: meta[:status],
        content_type: meta[:content_type],
        kind: kind,
        text: Nano.Util.clip(text, max: max),
        chars: String.length(text),
        truncated: String.length(text) > max,
        handle: handle,
        cached: meta[:cached] == true,
        prompt: Keyword.get(opts, :prompt),
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    end
  end

  defp normalize_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") -> {:ok, url}
      String.contains?(url, ".") -> {:ok, "https://" <> url}
      true -> {:error, {:bad_url, url}}
    end
  end

  defp normalize_url(other), do: {:error, {:bad_url, other}}

  # HTTP first; on HTML use readability (or Lightpanda for a page that needs JavaScript); PDFs go
  # to pdftotext; anything else is returned raw.
  defp to_text(body, url, meta, opts) do
    content_type = to_string(meta[:content_type] || "")
    mode = Keyword.get(opts, :mode, :markdown)

    cond do
      mode == :raw ->
        {body, :raw}

      mode == :lightpanda ->
        {lightpanda(url, opts), :lightpanda}

      Nano.Web.Extract.pdf?(body) or String.contains?(content_type, "application/pdf") ->
        case Nano.Web.Extract.pdf(body) do
          {:ok, text} -> {text, :pdf}
          {:error, _} -> {Nano.Web.Extract.elixir_html(body), :html_fallback}
        end

      Nano.Web.Extract.html?(body) ->
        {:ok, text} = Nano.Web.Extract.html(body, opts)
        {Nano.Web.Extract.decode_entities(text), :html}

      String.starts_with?(content_type, "text/") or String.starts_with?(content_type, "application/json") ->
        {body, :text}

      true ->
        {body, :other}
    end
  end

  ## lightpanda: a page that needs JavaScript

  @doc """
  Fetches `url` with the image's headless browser and returns its Markdown
  (`lightpanda fetch --dump markdown`). Use it when plain HTTP gives a shell of a page.
  """
  def lightpanda(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @limits.timeout_ms) |> div(1_000)

    case System.find_executable("lightpanda") do
      nil ->
        ""

      _ ->
        r = Nano.Util.sh("timeout #{timeout} lightpanda fetch --dump markdown " <> Nano.Util.shell_quote(url) <> " 2>/dev/null", timeout: (timeout + 5) * 1_000)
        r.out
    end
  end

  ## web_search

  @doc """
  Searches the web. Returns `{:ok, %{provider:, query:, results: [%{title:, url:, snippet:}],
  handle:}}` or `{:error, reason}`. Options: `num_results:` (default 5, max 20), `provider:`
  (`:exa`, `:wikipedia`, `:duckduckgo`), `include_content: true` (fetch each result's text).
  """
  def web_search(query, opts \\ []) do
    num = opts |> Keyword.get(:num_results, @limits.search_results) |> min(@limits.search_max)
    provider = Keyword.get(opts, :provider)

    {used, results} =
      case search(query, num, provider) do
        {:ok, results, used} -> {used, results}
        {:error, reason} -> {provider || :none, {:error, reason}}
      end

    case results do
      {:error, reason} ->
        {:error, reason}

      results ->
        results = if Keyword.get(opts, :include_content, false), do: Enum.map(results, &with_content/1), else: results
        text = Enum.map_join(results, "\n\n", fn r -> "#{r[:title]}\n#{r[:url]}\n#{String.slice(r[:snippet] || "", 0, 300)}" end)

        {:ok, %{provider: used, query: query, results: results, handle: store(query, text)}}
    end
  end

  defp with_content(%{url: url} = r) do
    case fetch_one(url, max: 3_000) do
      %{text: text} -> Map.put(r, :text, text)
      _ -> r
    end
  end

  defp search(query, num, :exa), do: exa(query, num)
  defp search(query, num, :wikipedia), do: wikipedia(query, num)
  defp search(query, num, :duckduckgo), do: duckduckgo(query, num)
  defp search(query, num, nil), do: default_search(query, num)
  defp search(_query, _num, other), do: {:error, {:unknown_provider, other}}

  defp default_search(query, num) do
    if present?(System.get_env("EXA_API_KEY")) do
      case exa(query, num) do
        {:ok, _, _} = ok -> ok
        {:error, _} -> try_keyless(query, num)
      end
    else
      try_keyless(query, num)
    end
  end

  defp try_keyless(query, num) do
    case duckduckgo(query, num) do
      {:ok, [], _} -> wikipedia(query, num)
      {:ok, _, _} = ok -> ok
      {:error, _} -> wikipedia(query, num)
    end
  end

  @doc false
  def exa(query, num) do
    key = System.get_env("EXA_API_KEY")

    if present?(key) do
      case Req.post("https://api.exa.ai/search",
             json: %{query: query, numResults: num, contents: %{text: %{maxCharacters: 2_000}}},
             headers: [{"x-api-key", key}],
             receive_timeout: @limits.timeout_ms,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"results" => results}}} ->
          {:ok, Enum.map(results, &exa_result/1), :exa}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exa, status, body}}

        {:error, e} ->
          {:error, {:exa, e}}
      end
    else
      {:error, :no_exa_key}
    end
  end

  defp exa_result(r),
    do: %{title: r["title"], url: r["url"], snippet: String.slice(r["text"] || r["snippet"] || "", 0, 400), text: r["text"]}

  # Keyless fallbacks. Wikipedia for reference facts; DuckDuckGo's HTML endpoint otherwise (it
  # rate-limits a busy node, so its failure falls through to Wikipedia rather than raising).
  @doc false
  def wikipedia(query, num) do
    url = "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=#{num}&srsearch=" <> URI.encode_www_form(query)

    case Req.get(url, receive_timeout: @limits.timeout_ms, retry: false) do
      {:ok, %{status: 200, body: %{"query" => %{"search" => hits}}}} ->
        {:ok,
         Enum.map(hits, fn h ->
           %{title: h["title"], url: "https://en.wikipedia.org/wiki/" <> URI.encode_www_form(String.replace(h["title"], " ", "_")),
             snippet: strip_tags(h["snippet"] || "")}
         end), :wikipedia}

      {:ok, %{status: status}} -> {:error, {:wikipedia, status}}
      {:error, e} -> {:error, {:wikipedia, e}}
    end
  end

  @doc false
  def duckduckgo(query, num) do
    url = "https://html.duckduckgo.com/html/?q=" <> URI.encode_www_form(query)

    case Req.get(url, receive_timeout: @limits.timeout_ms, retry: false,
                  headers: [{"user-agent", "Mozilla/5.0 (compatible; nano-agent)"}]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        results =
          ~r/<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/s
          |> Regex.scan(body)
          |> Enum.take(num)
          |> Enum.map(fn [_, href, title] ->
            %{title: strip_tags(title), url: ddg_url(href), snippet: ""}
          end)

        {:ok, results, :duckduckgo}

      {:ok, %{status: status}} -> {:error, {:duckduckgo, status}}
      {:error, e} -> {:error, {:duckduckgo, e}}
    end
  end

  defp ddg_url(href) do
    case URI.decode_www_form(href) do
      decoded ->
        case Regex.run(~r/[?&]uddg=([^&]+)/, decoded) do
          [_, u] -> URI.decode_www_form(u)
          _ -> if String.starts_with?(decoded, "//"), do: "https:" <> decoded, else: decoded
        end
    end
  end

  defp strip_tags(text), do: text |> String.replace(~r/<[^>]+>/, "") |> Nano.Web.Extract.decode_entities()

  @doc """
  Asks Exa to answer a question with citations (`api.exa.ai/answer`). `{:ok, %{answer:, citations:}}`
  or `{:error, :no_exa_key | reason}`. Exa's *research* agent (an agentic deep-research run) was
  retired by Exa and now returns 410, so this is the answering endpoint that exists; `search.md`
  asks for the research agent and this node cannot supply it.
  """
  def exa_answer(query, opts \\ []) do
    key = System.get_env("EXA_API_KEY")

    if present?(key) do
      case Req.post("https://api.exa.ai/answer",
             json: %{query: query, text: Keyword.get(opts, :text, true)},
             headers: [{"x-api-key", key}],
             receive_timeout: @limits.timeout_ms,
             retry: false
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, %{answer: body["answer"], citations: body["citations"], handle: store(query, body["answer"] || "")}}

        {:ok, %{status: status, body: body}} -> {:error, {:exa_answer, status, body}}
        {:error, e} -> {:error, {:exa_answer, e}}
      end
    else
      {:error, :no_exa_key}
    end
  end

  ## get_search_content

  @doc """
  Reads back stored content by `handle` (from `fetch_content/2` or `web_search/2`), paged:

    * `offset:` / `limit:` — a window of characters (default 4,000)
    * `search:` — a substring, returning it with context and character offsets

  Returns `%{handle:, chars:, offset:, limit:, text:, total:, more:}` or `{:error, reason}`.
  """
  def get_search_content(handle, opts \\ []) do
    case get(handle) do
      nil ->
        {:error, {:unknown_handle, handle}}

      %{text: text, at: at} = entry ->
        url = Map.get(entry, :url)
        cond do
          search = Keyword.get(opts, :search) ->
            matches = find_matches(text, search)
            %{handle: handle, url: url, at: at, search: search, chars: String.length(text), matches: matches}

          true ->
            offset = Keyword.get(opts, :offset, 0)
            limit = Keyword.get(opts, :limit, @limits.page_chars)
            slice = String.slice(text, offset, limit)
            total = String.length(text)

            %{
              handle: handle,
              url: url,
              at: at,
              chars: total,
              offset: offset,
              limit: limit,
              text: slice,
              more: offset + limit < total
            }
        end
    end
  end

  defp find_matches(text, needle) do
    len = String.length(needle)

    text
    |> String.split(needle)
    |> Enum.reduce({[], 0}, fn part, {acc, at} ->
      part_len = String.length(part)
      found_at = at
      next = at + part_len + len

      match = %{
        at: found_at,
        before: if(found_at > 0, do: String.slice(text, max(found_at - 120, 0), 120), else: ""),
        after: String.slice(text, found_at + len, 120)
      }

      {[match | acc], next}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.take(20)
  end


  ## source_check

  @doc """
  Gathers evidence for a claim: fetches sources (the claim's own words as a search, or `sources:`
  you give), and returns the passages that mention its terms, with a status:

    * `:supported` — a passage contains most of the claim's distinctive terms
    * `:unclear` — some terms appear, not enough to call it supported
    * `:missing_evidence` — nothing relevant was found
    * (`:contradicted` needs a model to judge negation; not attempted here, and said so rather
      than faked)

  Options: `sources:` (URLs to use instead of searching), `num:` (how many search results).
  """
  def source_check(claim, opts \\ []) do
    sources =
      case Keyword.get(opts, :sources) do
        nil ->
          case web_search(claim, num_results: Keyword.get(opts, :num, 3)) do
            {:ok, %{results: results}} -> Enum.map(results, & &1[:url]) |> Enum.reject(&is_nil/1)
            _ -> []
          end

        urls -> urls
      end

    terms = claim |> String.downcase() |> String.split(~r/[^a-z0-9]+/) |> Enum.reject(&(String.length(&1) < 4)) |> Enum.uniq()

    passages =
      sources
      |> Enum.take(5)
      |> Enum.flat_map(fn url ->
        case fetch_one(url, max: @limits.content_chars) do
          %{text: text} -> passages_for(url, text, terms)
          _ -> []
        end
      end)

    status =
      cond do
        Enum.any?(passages, &(&1.score >= 0.6)) -> :supported
        Enum.any?(passages, &(&1.score >= 0.3)) -> :unclear
        true -> :missing_evidence
      end

    %{claim: claim, status: status, sources: sources, passages: passages, terms: terms,
      note: "contradicted is not decided here: judging negation needs a model, and none was spent on it."}
  end

  defp passages_for(url, text, terms) do
    sentences = Regex.split(~r/(?<=[.!?])\s+/, text)

    sentences
    |> Enum.with_index()
    |> Enum.map(fn {s, i} -> %{url: url, at: i, text: String.slice(s, 0, 400), score: score(s, terms)} end)
    |> Enum.filter(&(&1.score > 0))
    |> Enum.sort_by(& -&1.score)
    |> Enum.take(3)
  end

  defp score(sentence, terms) do
    down = String.downcase(sentence)

    case terms do
      [] -> 0.0
      terms ->
        hits = Enum.count(terms, &String.contains?(down, &1))
        hits / length(terms)
    end
  end

  ## fetching and the cache

  # HTTP, cache-aware. One hour, bounded, keyed by URL. The cache lives in the module's GenServer
  # (`Nano.Web.Cache`), so it survives across evals and dies with the node.
  defp cached_fetch(url, opts) do
    refresh = Keyword.get(opts, :refresh, false)

    case not refresh && Nano.Web.Cache.get(url) do
      %{body: body, meta: meta} -> {:ok, body, Map.put(meta, :cached, true)}
      _ -> do_fetch(url, opts)
    end
  end

  defp do_fetch(url, opts) do
    timeout = Keyword.get(opts, :timeout, @limits.timeout_ms)

    case Req.get(url, receive_timeout: timeout, retry: false, redirect: true,
                 headers: [{"user-agent", "Mozilla/5.0 (compatible; nano-agent)"}],
                 decode_body: false, max_redirects: 5) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        meta = %{
          status: status,
          content_type: header(headers, "content-type"),
          final_url: url,
          at: System.system_time(:millisecond)
        }

        if byte_size(body) <= @limits.max_bytes do
          Nano.Web.Cache.put(url, body, meta)
          {:ok, body, meta}
        else
          {:error, {:too_large, byte_size(body)}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, e} ->
        {:error, {:transport, e}}
    end
  end

  defp header(headers, name) do
    headers
    |> Enum.filter(fn {k, _} -> String.downcase(to_string(k)) == name end)
    |> Enum.map(fn {_, v} -> v |> List.wrap() |> List.last() |> to_string() end)
    |> List.first()
  end

  ## stored content (handles)

  defp store(label, text), do: Nano.Web.Cache.store(label, text)
  defp get(handle), do: Nano.Web.Cache.get_stored(handle)
end
