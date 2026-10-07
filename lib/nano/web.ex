defmodule Nano.Web do
  @moduledoc """
  Search the web and read pages, from `eval`. A port of pi's `pi-web-access`
  (`seedings/web-access.md`), keeping its names where they fit.

      Nano.Web.fetch_content("https://example.com")                       # readable text
      Nano.Web.fetch_content(["https://a", "https://b"], mode: :raw)      # raw bodies
      Nano.Web.fetch_content("https://ex.com", prompt: "what is the price?")  # answer from the page
      Nano.Web.web_search("OTP 29 release notes", num_results: 5)
      Nano.Web.get_search_content(response_id, offset: 0, limit: 20_000)  # page stored content
      Nano.Web.source_check("the BEAM has preemptive scheduling")         # evidence for a claim

  ## Providers

  `web_search/2` uses the first provider that has credentials, in this order:

    * **Exa** — needs `EXA_API_KEY` (see `seedings/search.md`); the API at `https://api.exa.ai`.
    * **DuckDuckGo** — no key: the HTML endpoint is scraped and the results parsed. Works on
      this node today; less reliable than an API, and it may rate-limit.

  `provider:` forces one (`:exa`, :duckduckgo`), `""`/`nil` picks automatically. On a node
  without `EXA_API_KEY` the available providers are reported by `providers/0`, and each
  function's `missing` says what a key would add. Fetching and extraction need no key at all.

  ## Reading

  `fetch_content/2` fetches over plain HTTP (redirects followed, 30 s timeout), then:

    * for HTML: Readability (Mozilla's, via jsdom in `priv/web/extract.js`) to text;
    * for PDFs: `pdftotext` (poppler) when it is installed;
    * for GitHub repositories: the repository's `README` (cloned shallowly when `:clone`);
    * video: not supported on this node — reported, not faked.

  Content is cached for an hour (a bounded cache, `cache_status/0`, `clear_cache/0`), sliced
  to `limits().content_bytes` (about 30,000 characters), and paged with `get_search_content/2`
  so a long page never has to enter the agent's context whole.

  Bounds live in `limits/0`.
  """

  @limits %{
    content_bytes: 30_000,
    snippets: 5,
    max_results: 20,
    timeout_ms: 30_000,
    cache_ms: 3_600_000,
    cache_entries: 100,
    search_bytes: 4_000
  }

  @user_agent "Mozilla/5.0 (compatible; nano-agent/0.1; +https://github.com/mikekelly/lolwut)"

  @doc "The bounds this module applies: `content_bytes`, `snippets`, `max_results`, `timeout_ms`, `cache_ms`, `cache_entries`, `search_bytes`."
  def limits, do: @limits

  @doc "Which search providers are usable on this node: `[%{id:, available:, needs:}]`."
  def providers do
    [
      %{id: :exa, available: exa_key() != nil, needs: "EXA_API_KEY"},
      %{
        id: :duckduckgo,
        available: true,
        needs: nil,
        note: "the HTML endpoint rate-limits by IP; retry or set EXA_API_KEY"
      },
      %{id: :wikipedia, available: true, needs: nil, note: "encyclopedic results only"}
    ]
  end

  ## fetch_content

  @doc """
  Fetches one or more URLs and returns readable content. Options:

    * `mode:` — `:readable` (default: extraction to text), `:raw` (the body as it came),
      `:markdown` (readable text with light heading/bullet markup for HTML)
    * `prompt:` — return an answer to this question about the page instead of the whole text
      (the page text plus the question are handed to `Nano.OpenRouter`; the model default)
    * `max_bytes:` — slice length (default `limits().content_bytes`)

  Returns one map for a single URL, a list of maps for several:
  `%{url:, final_url:, status:, content_type:, title:, excerpt:, content:, bytes:, slice:,
  truncated:, cached:, pdf:, error:}`. Never raises; failures are `error:` strings.
  """
  def fetch_content(urls, opts \\ [])

  def fetch_content(urls, opts) when is_binary(urls) do
    fetch_one(urls, opts)
  end

  def fetch_content(urls, opts) when is_list(urls) do
    Enum.map(urls, &fetch_one(&1, opts))
  end

  defp fetch_one(url, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @limits.content_bytes)
    mode = Keyword.get(opts, :mode, :readable)

    case fetch_raw(url) do
      {:ok, %{body: body, content_type: ct, final_url: final, status: status} = _resp} ->
        {kind, text, meta} = extract(body, ct, final, mode, opts)

        result = %{
          url: url,
          final_url: final,
          status: status,
          content_type: ct,
          kind: kind,
          title: meta[:title],
          excerpt: meta[:excerpt],
          byline: meta[:byline],
          bytes: byte_size(text),
          content: Nano.Util.clip(text, max: max_bytes),
          truncated: byte_size(text) > max_bytes
        }

        result =
          case Keyword.get(opts, :prompt) do
            nil -> result
            prompt -> Map.put(result, :answer, answer_from(result, prompt))
          end

        store(result)

      {:error, reason} ->
        failed(url, reason)
    end
  end

  @doc """
  Fetches a URL with no extraction: `{:ok, %{status:, headers:, body:, content_type:,
  final_url:, bytes:}}` or `{:error, reason}`. Cached for an hour.
  """
  def fetch_raw(url) do
    case cache_get({:raw, url}) do
      nil ->
        result = do_fetch(url)
        if match?({:ok, _}, result), do: cache_put({:raw, url}, result)
        result

      cached ->
        cached
    end
  end

  defp do_fetch(url) do
    opts = [
      retry: false,
      redirect: true,
      receive_timeout: @limits.timeout_ms,
      connect_options: [timeout: 10_000],
      headers: [
        {"user-agent", @user_agent},
        {"accept", "text/html,application/pdf,text/plain,*/*"}
      ]
    ]

    case Req.get(url, opts) do
      {:ok, %{status: status, body: body, headers: headers} = resp} when status in 200..299 ->
        {:ok,
         %{
           status: status,
           headers: headers,
           body: body,
           content_type: header(headers, "content-type") || "",
           final_url: resp.private[:final_url] || url,
           bytes: byte_size(to_string(body))
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{String.slice(to_string(body), 0, 200)}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  defp extract(body, ct, url, mode, opts) do
    cond do
      String.contains?(ct, "application/pdf") or pdf_magic?(body) ->
        case pdf_to_text(body) do
          {:ok, text, title} -> {:pdf, text, %{title: title}}
          {:error, reason} -> raise_or_report({:pdf, reason})
        end

      github_repo?(url) and Keyword.get(opts, :github, :readme) == :readme ->
        case github_readme(url) do
          {:ok, text} -> {:github, text, %{title: url}}
          {:error, reason} -> {:text, "GitHub: #{reason}", %{}}
        end

      String.contains?(ct, "text/html") or html?(body) ->
        article = readable(body)
        text = if mode == :raw, do: to_string(body), else: article["text"] || ""

        {if(mode == :raw, do: :html_raw, else: :readable), text,
         %{title: article["title"], excerpt: article["excerpt"], byline: article["byline"]}}

      String.contains?(ct, "text/") or json?(ct) ->
        {:text, to_string(body), %{}}

      true ->
        {:binary, "Content-Type #{ct} (#{byte_size(to_string(body))} bytes); not text.", %{}}
    end
  end

  defp raise_or_report({_kind, reason}), do: {:text, "Extraction failed: #{reason}", %{}}

  defp readable(html) do
    fallback = %{"text" => strip_tags(html), "title" => title(html)}
    script = Path.join([Nano.Util.app_dir(), "priv", "web", "extract.js"])

    case System.find_executable("node") do
      nil ->
        fallback

      _node ->
        # The document goes through a file (a piped stdin blocks under the eval's group
        # leader, which never reaches EOF until the eval ends).
        input =
          Path.join(System.tmp_dir!(), "nano-web-#{System.unique_integer([:positive])}.html")

        try do
          File.write!(input, html)

          case Nano.Util.sh(
                 "node #{Nano.Util.shell_quote(script)} < #{Nano.Util.shell_quote(input)}",
                 env: [{"NODE_PATH", node_modules()}],
                 timeout: 20_000
               ) do
            %{status: 0, out: out} ->
              case Jason.decode(out) do
                {:ok, map} -> map
                _ -> fallback
              end

            _ ->
              fallback
          end
        after
          File.rm(input)
        end
    end
  end

  defp node_modules, do: Path.join([Nano.Util.app_dir(), "priv", "web", "node_modules"])

  @doc false
  # A small HTML-to-text fallback (no jsdom): strips scripts/styles/tags and decodes entities.
  def strip_tags(html) do
    html
    |> String.replace(~r/<script[\s\S]*?<\/script>/i, " ")
    |> String.replace(~r/<style[\s\S]*?<\/style>/i, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp title(html) do
    with [_, t] <- Regex.run(~r/<title[^>]*>([^<]*)<\/title>/i, html),
         do: String.trim(t),
         else: (_ -> nil)
  end

  defp pdf_magic?(body) when is_binary(body), do: String.starts_with?(body, "%PDF")
  defp pdf_magic?(_), do: false

  defp pdf_to_text(body) do
    case System.find_executable("pdftotext") do
      nil ->
        {:error, "pdftotext is not installed (apt-get install poppler-utils)"}

      _ ->
        path = Path.join(System.tmp_dir!(), "nano-web-#{System.unique_integer([:positive])}.pdf")
        File.write!(path, body)

        try do
          case Nano.Util.sh("pdftotext -q #{Nano.Util.shell_quote(path)} -") do
            %{status: 0, out: text} -> {:ok, text, nil}
            %{out: out} -> {:error, "pdftotext: #{String.slice(out, 0, 200)}"}
          end
        after
          File.rm(path)
        end
    end
  end

  defp github_repo?(url), do: url =~ ~r{^https?://github\.com/[\w.-]+/[\w.-]+/?$}

  defp github_readme(url) do
    repo = url |> String.replace(~r{^https?://github\.com/}, "") |> String.trim_trailing("/")

    for branch <- ~w(HEAD main master), name <- ~w(README.md README.rst README.txt readme.md) do
      case Req.get("https://raw.githubusercontent.com/#{repo}/#{branch}/#{name}",
             retry: false,
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: text}} when is_binary(text) -> throw({:ok, text})
        _ -> :ok
      end
    end

    {:error, "no README at HEAD"}
  catch
    {:ok, text} -> {:ok, text}
  end

  defp answer_from(result, prompt) do
    model = Application.get_env(:nano, :default_model)
    text = Nano.Util.clip(result.content, max: 12_000)

    messages = [
      %{
        "role" => "system",
        "content" =>
          "Answer the question using only the page text given. Quote short excerpts as evidence. If the text does not answer it, say so."
      },
      %{
        "role" => "user",
        "content" => "Page: #{result.final_url}\n\n#{text}\n\nQuestion: #{prompt}"
      }
    ]

    case Nano.OpenRouter.chat(model, messages, [], "off") do
      {:ok, %{message: %{"content" => content}}} -> content
      {:ok, %{message: msg}} -> msg["content"]
      {:error, error} -> "could not answer from the page: #{inspect(error)}"
    end
  end

  defp failed(url, reason) do
    %{url: url, error: to_string(reason), content: nil, bytes: 0, truncated: false}
  end

  ## web_search

  @doc """
  Searches the web. Options:

    * `num_results:` — 1..`limits().max_results` (default `limits().snippets`, 5)
    * `recency:` — `:day`, `:week`, `:month`, `:year` (or Exa's `"pastWeek"` string)
    * `domains:` — a list of domains to include
    * `include_content:` — also fetch and store each result's page (off by default, so a
      search stays small)
    * `provider:` — `:exa` or `:duckduckgo`; default: the first available

  Returns `%{provider:, query:, results: [%{title:, url:, snippet:, published:, author:,
  score:}], missing: ...}`. Each call is stored under a `response_id`, so
  `get_search_content/2` can page the result later.
  """
  def web_search(query, opts \\ []) do
    num = min(Keyword.get(opts, :num_results, @limits.snippets), @limits.max_results)
    result = search(query, num, opts)

    result = Map.merge(%{query: query, num_results: num}, result)
    result = if Keyword.get(opts, :include_content, false), do: with_content(result), else: result
    store(Map.put(result, :url, "search://#{result[:provider]}/#{URI.encode(query)}"))
  end

  defp search(query, num, opts) do
    case Keyword.get(opts, :provider) do
      nil -> auto_search(query, num, opts)
      :exa -> wrap_provider(:exa, search_exa(query, num, opts))
      :duckduckgo -> wrap_provider(:duckduckgo, search_duckduckgo(query, num, opts))
      :wikipedia -> wrap_provider(:wikipedia, search_wikipedia(query, num, opts))
      other -> %{provider: other, error: "unknown provider #{inspect(other)}", results: []}
    end
  end

  # With no provider named: Exa if the key is there, else DuckDuckGo, falling back to
  # Wikipedia when DuckDuckGo rate-limits (its keyless HTML endpoint does so by IP).
  defp auto_search(query, num, opts) do
    cond do
      exa_key() != nil ->
        wrap_provider(:exa, search_exa(query, num, opts))

      true ->
        case search_duckduckgo(query, num, opts) do
          %{results: [_ | _]} = r ->
            wrap_provider(:duckduckgo, r)

          %{error: message} = _ddg ->
            wrap_provider(:wikipedia, search_wikipedia(query, num, opts))
            |> Map.put(:fell_back_from, message)

          other ->
            wrap_provider(:duckduckgo, other)
        end
    end
  end

  defp wrap_provider(provider, result), do: Map.put(result, :provider, provider)

  defp search_exa(query, num, opts) do
    key = exa_key()

    if key == nil do
      %{
        error: "EXA_API_KEY is not set; using the DuckDuckGo fallback",
        results: search_duckduckgo(query, num, opts)[:results] || []
      }
    else
      body =
        %{
          "query" => query,
          "numResults" => num,
          "type" => "auto",
          "contents" => %{"text" => %{"maxCharacters" => 200}}
        }
        |> maybe_put("category", Keyword.get(opts, :category))
        |> maybe_put("includeDomains", Keyword.get(opts, :domains))
        |> maybe_put("startPublishedDate", recency_date(Keyword.get(opts, :recency)))

      case Req.post("https://api.exa.ai/search",
             json: body,
             headers: [{"x-api-key", key}],
             retry: false,
             receive_timeout: @limits.timeout_ms
           ) do
        {:ok, %{status: 200, body: %{"results" => results}}} ->
          %{results: Enum.map(results, &exa_result/1), missing: nil}

        {:ok, %{status: status, body: body}} ->
          %{error: "Exa HTTP #{status}: #{inspect(body) |> String.slice(0, 300)}", results: []}

        {:error, e} ->
          %{error: Exception.message(e), results: []}
      end
    end
  end

  defp exa_result(r) do
    %{
      title: r["title"],
      url: r["url"],
      snippet: r["text"] || r["summary"] || "",
      published: r["publishedDate"],
      author: r["author"],
      score: r["score"]
    }
  end

  defp search_duckduckgo(query, num, _opts) do
    url = "https://html.duckduckgo.com/html/?q=" <> URI.encode_www_form(query)

    case Req.get(url,
           headers: [{"user-agent", @user_agent}],
           retry: false,
           receive_timeout: @limits.timeout_ms
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        results = parse_ddg(body) |> Enum.take(num)

        %{
          results: results,
          missing: if(exa_key(), do: nil, else: "EXA_API_KEY (Exa gives cleaner results)")
        }

      {:ok, %{status: status}} ->
        %{
          error: "DuckDuckGo HTTP #{status} (it rate-limits; try again or set EXA_API_KEY)",
          results: []
        }

      {:error, e} ->
        %{error: Exception.message(e), results: []}
    end
  end

  # Wikipedia's action API: keyless, reliable, and good for factual and encyclopedic
  # queries. Not a general web search, but a real fallback when nothing else is available.
  defp search_wikipedia(query, num, _opts) do
    url =
      "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=" <>
        URI.encode_www_form(query) <>
        "&srlimit=#{min(num, 20)}&format=json&srprop=" <> URI.encode_www_form("snippet|timestamp")

    case Req.get(url,
           retry: false,
           receive_timeout: @limits.timeout_ms,
           headers: [{"user-agent", @user_agent}]
         ) do
      {:ok, %{status: 200, body: %{"query" => %{"search" => hits}}}} ->
        %{
          results:
            Enum.map(hits, fn hit ->
              %{
                title: hit["title"],
                url:
                  "https://en.wikipedia.org/wiki/" <>
                    URI.encode(hit["title"] |> String.replace(" ", "_")),
                snippet: strip_tags(hit["snippet"] || ""),
                published: hit["timestamp"],
                author: nil,
                score: nil
              }
            end),
          missing: "EXA_API_KEY (Exa searches the whole web; Wikipedia is encyclopedic only)"
        }

      {:ok, %{status: status}} ->
        %{error: "Wikipedia HTTP #{status}", results: []}

      {:error, e} ->
        %{error: Exception.message(e), results: []}
    end
  end

  # The HTML endpoint: result blocks are `<a class="result__a" href="…">title</a>` with a
  # `result__snippet`. DuckDuckGo wraps URLs in a redirect (`uddg=`), which we unwrap.
  defp parse_ddg(html) do
    html
    |> String.split(~r{<div[^>]*class="[^"]*result__body})
    |> Enum.drop(1)
    |> Enum.map(fn block ->
      %{
        title: ddg_text(block, ~r{class="result__a"[^>]*>(.*?)</a>}s),
        url: ddg_url(block),
        snippet: ddg_text(block, ~r{class="result__snippet"[^>]*>(.*?)</a>}s)
      }
    end)
    |> Enum.reject(&is_nil(&1.url))
  end

  defp ddg_text(block, regex) do
    case Regex.run(regex, block) do
      [_, inner] -> inner |> strip_tags() |> String.trim()
      _ -> nil
    end
  end

  defp ddg_url(block) do
    with [_, href] <- Regex.run(~r{class="result__a"[^>]*href="([^"]+)"}s, block) do
      cond do
        href =~ "uddg=" ->
          href
          |> URI.decode()
          |> then(&Regex.run(~r/[?&]uddg=([^&]+)/, &1))
          |> case do
            [_, enc] -> URI.decode_www_form(enc)
            _ -> href
          end

        true ->
          href
      end
    else
      _ -> nil
    end
  end

  defp with_content(result) do
    results =
      for r <- result[:results] || [], r[:url] do
        case get_search_content_by_url(r[:url]) do
          nil -> r
          content -> Map.put(r, :content, content)
        end
      end

    %{result | results: results}
  end

  defp get_search_content_by_url(url) do
    case fetch_raw(url) do
      {:ok, %{body: body, content_type: ct, final_url: final}} ->
        {_kind, text, _meta} = extract(body, ct, final, :readable, [])
        Nano.Util.clip(text, max: 4_000)

      _ ->
        nil
    end
  end

  ## get_search_content

  @doc """
  Reads back content stored by an earlier `web_search/2` or `fetch_content/2`, by response id
  (the `response_id` in their return) or by URL. Options: `offset:` (default 0), `limit:`
  (default `limits().content_bytes`), or `search:` — a substring to find and window around.
  Returns `%{response_id:, url:, title:, offset:, limit:, total_bytes:, content:, sources:}`
  or `{:error, :not_found | :expired}`.
  """
  def get_search_content(id, opts \\ []) do
    case cache_get({:stored, id}) || cache_get({:stored, lookup_url(id)}) do
      nil -> {:error, :not_found}
      %{content: content} = stored -> window(stored, content, opts)
      %{results: _} = stored -> window(stored, results_text(stored), opts)
      other -> window(other, to_string(other[:content] || ""), opts)
    end
  end

  defp lookup_url(id) do
    case cache_get({:stored, id}) do
      %{url: url} -> url
      _ -> id
    end
  end

  defp results_text(stored) do
    Enum.map_join(stored[:results] || [], "\n\n", fn r ->
      "#{r[:title]}\n#{r[:url]}\n#{r[:snippet]}#{if r[:content], do: "\n\n#{r[:content]}", else: ""}"
    end)
  end

  defp window(stored, content, opts) do
    content = content || ""
    total = byte_size(content)
    limit = Keyword.get(opts, :limit, @limits.content_bytes)

    offset =
      case Keyword.get(opts, :search) do
        nil ->
          Keyword.get(opts, :offset, 0)

        needle ->
          case :binary.match(content, needle) do
            {pos, _} -> max(pos - div(limit, 4), 0)
            :nomatch -> Keyword.get(opts, :offset, 0)
          end
      end

    slice =
      content |> binary_part(min(offset, max(total - 1, 0)), min(limit, max(total - offset, 0)))

    %{
      response_id: stored[:response_id] || stored[:url],
      url: stored[:url],
      title: stored[:title],
      offset: offset,
      limit: limit,
      total_bytes: total,
      content: Nano.Util.clip(slice, max: limit),
      sources: Enum.map(stored[:results] || [], & &1[:url])
    }
  end

  ## source_check

  @doc """
  Gathers evidence for a claim: searches for it and returns passages with a status. Without
  an LLM judgement (`judge: false`) every passage is reported `unclear` with its source, so
  the caller can decide. With `judge: true` (and a model) each passage is marked
  `supported`, `contradicted`, `unclear` or `missing` (no passages at all).

  Returns `%{claim:, status:, passages: [%{source:, text:, status:, stance:}], provider:,
  checked_at:}`.
  """
  def source_check(claim, opts \\ []) do
    num = Keyword.get(opts, :num_results, 5)
    judge? = Keyword.get(opts, :judge, true)

    search =
      web_search(claim,
        num_results: num,
        include_content: true,
        provider: Keyword.get(opts, :provider)
      )

    passages =
      for r <- search[:results] || [], r[:content] do
        %{
          source: r[:url],
          title: r[:title],
          text: Nano.Util.clip(r[:content], max: 1_200),
          status: if(judge?, do: judge_passage(claim, r[:content]), else: :unclear)
        }
      end

    status =
      cond do
        passages == [] -> :missing
        Enum.any?(passages, &(&1.status == :contradicted)) -> :contradicted
        Enum.any?(passages, &(&1.status == :supported)) -> :supported
        true -> :unclear
      end

    %{
      claim: claim,
      status: status,
      passages: passages,
      provider: search[:provider],
      search_error: search[:error],
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp judge_passage(claim, passage) do
    model = Application.get_env(:nano, :default_model)

    messages = [
      %{
        "role" => "system",
        "content" =>
          "Reply with exactly one word: supported, contradicted, or unclear — whether the passage speaks to the claim."
      },
      %{
        "role" => "user",
        "content" => "Claim: #{claim}\n\nPassage: #{Nano.Util.clip(passage, max: 2_000)}"
      }
    ]

    case Nano.OpenRouter.chat(model, messages, [], "off") do
      {:ok, %{message: msg}} ->
        case String.downcase(to_string(msg["content"])) do
          "supported" -> :supported
          "contradicted" -> :contradicted
          _ -> :unclear
        end

      _ ->
        :unclear
    end
  end

  ## Cache and storage

  @doc "Cache and response-store statistics: `%{entries:, bytes:, oldest:, newest:}`."
  def cache_status do
    entries = :ets.tab2list(Nano.Web.Cache.table())
    now = System.monotonic_time(:millisecond)

    %{
      entries: length(entries),
      bytes: entries |> Enum.map(&:erlang.external_size/1) |> Enum.sum(),
      oldest: entries |> Enum.map(fn {_, e} -> now - e.at end) |> Enum.max(fn -> 0 end),
      newest: now
    }
  end

  @doc "Empties the cache and the response store."
  def clear_cache do
    :ets.delete_all_objects(Nano.Web.Cache.table())
    :ok
  end

  defp store(result) do
    id = response_id(result)

    entry =
      result
      |> Map.put(:response_id, id)
      |> Map.put(:at, System.monotonic_time(:millisecond))

    cache_put({:stored, id}, entry)
    if result[:url], do: cache_put({:stored, result[:url]}, entry)
    Map.put(result, :response_id, id)
  end

  defp response_id(result) do
    ("r" <>
       Base.encode16(:crypto.hash(:sha256, to_string(result[:url]) <> to_string(result[:query]))))
    |> binary_part(0, 10)
    |> String.downcase()
  end

  defp cache_get(key) do
    case :ets.lookup(Nano.Web.Cache.table(), key) do
      [{^key, %{at: at} = value}] ->
        if System.monotonic_time(:millisecond) - at < @limits.cache_ms,
          do: Map.get(value, :value, value)

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp cache_put(key, value) do
    table = Nano.Web.Cache.table()
    :ets.insert(table, {key, %{at: System.monotonic_time(:millisecond), value: value}})
    trim(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp trim(table) do
    if :ets.info(table, :size) > @limits.cache_entries do
      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_, e} -> e.at end)
      |> Enum.take(:ets.info(table, :size) - @limits.cache_entries)
      |> Enum.each(fn {k, _} -> :ets.delete(table, k) end)
    end
  end

  ## Helpers

  defp exa_key do
    with key when key not in [nil, ""] <- System.get_env("EXA_API_KEY"), do: key
  end

  defp header(headers, name) do
    headers
    |> Enum.filter(fn {k, _} -> String.downcase(to_string(k)) == name end)
    |> Enum.map(fn {_, v} -> v |> List.wrap() |> List.last() |> to_string() end)
    |> List.first()
  end

  defp html?(body),
    do:
      is_binary(body) and (String.contains?(body, "<html") or String.contains?(body, "<!DOCTYPE"))

  defp json?(ct), do: String.contains?(ct, "json")

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp recency_date(nil), do: nil
  defp recency_date(:day), do: date_days_ago(1)
  defp recency_date(:week), do: date_days_ago(7)
  defp recency_date(:month), do: date_days_ago(30)
  defp recency_date(:year), do: date_days_ago(365)
  defp recency_date(text) when is_binary(text), do: text
  defp recency_date(_), do: nil

  defp date_days_ago(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end
end

defmodule Nano.Web.Cache do
  @moduledoc "ETS cache and response store for `Nano.Web` (pages for an hour, latest 100 entries)."
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The public cache table (readers do not call this process)."
  def table, do: @table

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
