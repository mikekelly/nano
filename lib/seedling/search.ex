defmodule Seedling.Search do
  @moduledoc """
  Exa search, page contents, grounded answers and restart-safe async research.

      Seedling.Search.search("Elixir OTP supervision", limit: 5)
      Seedling.Search.contents(["https://elixir-lang.org"])
      Seedling.Search.answer("Who created Elixir?")
      {:ok, job} = Seedling.Search.research("Who created Elixir? Give an official source.",
        notify: {:agent, "atlas"}, effort: "minimal")
      # Later: {:seedling_research, job.id, %{status: ..., result_id: ...}}
      Seedling.Search.research_status(job)
      Seedling.Search.read(job_result.result_id, cache_dir: job_result.cache_dir)
      Seedling.Search.ack_research(job)

  Credentials are read only through `Nano.Settings.get("EXA_API_KEY")`. Never
  echoed, saved or placed in a shell command. Missing key is an actionable error.
  `settings: fn name -> ... end` is a per-call test seam. `transport` is the
  five-argument HTTP seam documented in Seedling.Web. No shared env changes.

  Search defaults to titles, ids, URLs and highlights, **never page text**. Fetch
  text in a second `contents/2` call. Each content result includes `content_id`
  for `Seedling.Web.read/2` and `Seedling.Web.evidence/3` with the original URL.
  Results/citations retain one-based `index` even when some are cut. Returns `{:ok, %{results: [...], ...}}`;
  answer returns `answer` and `citations`. Every returned string and the aggregate
  payload are bounded (`max_bytes: 12_000`, 4..40_000), and cuts are announced.
  Full responses are cached as JSON; `read(result_id, offset: ...)` pages them
  without paying Exa again. Cache options match Seedling.Web. `cost_dollars` and
  `request_id` are preserved when Exa supplies them. HTTP errors, quota/rate-limit
  failures and timeouts are values. No automatic retries on paid POSTs.

  Common options: `limit: 5` (1..100), `timeout: 20_000`, `params: %{...}` for
  current Exa provider fields (camelCase string keys), `base_url` (default
  `https://api.exa.ai`). Key-bearing requests never follow redirects. Contents
  asks for maxCharacters: 100_000 by default (`:content_chars`); provider-side
  truncation can occur and is called out independently of local display cuts.

  Current docs (https://exa.ai/docs/llms.txt, inspected 2026-10-08) replaced the
  old `/research` API with **`/agent/runs`**. `research/2` wraps that endpoint;
  `effort` defaults to `"low"` (fixed price); pass `output_schema: %{...}` for
  structured output, or supply `params` for advanced inputs/budgets. Exa's
  output.grounding contains field citations; a citation is not a guarantee of
  truth. Read and verify the cited pages.

  Research watchers are unlinked from their caller and persist handles/results
  under `jobs_dir` (default `/tmp/seedling-search-jobs`). **Use a named agent**
  recipient to survive agent restarts. Completed named-agent notifications are
  delivered at least once, retried every `notify_interval: 5000` until
  `ack_research/2`; duplicates are possible. A pid recipient is one-shot and
  cannot survive its death. Node/container restart needs `resume_research/2`
  with the persisted handle; no keys/functions are serialized. If initial job
  persistence failed, pass the returned remote handle (or id plus jobs_dir) to
  resume_research/2 after fixing storage: it recreates a local watch record and
  only GETs the existing remote run, never POSTs another paid run. Handles/events
  carry cache_dir for result paging. Cache eviction can invalidate result ids;
  copy important outputs elsewhere. Exa snapshot timestamps record local retrieval,
  not necessarily the provider's page crawl time. Polling defaults
  to 2000 ms, with `research_timeout: 600_000`. A local timeout does not cancel
  a paid remote run: resume watching or explicitly `cancel_research/2`.
  """
  alias Seedling.Web.{HTTP, Store}
  alias Seedling.Search.Research

  @doc "Search with bounded metadata/highlights, not full text."
  def search(query, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_search(query, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_search(query, opts) do
    limit = Keyword.get(opts, :limit, 5)

    with :ok <- validate_query(query),
         :ok <- validate_limit(limit),
         :ok <- validate_cap(opts),
         {:ok, data} <-
           api(
             :post,
             "/search",
             Map.merge(params(opts), %{
               "query" => query,
               "numResults" => limit,
               "contents" => %{"highlights" => %{"maxCharacters" => 800}}
             }),
             opts
           ),
         {:ok, meta} <- snapshot(data, "search", opts) do
      compact_results(data, meta, opts, false)
    end
  end

  @doc "Retrieve text for Exa ids or URLs; full JSON remains cached for paging."
  def contents(ids, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_contents(ids, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_contents(ids, opts) do
    chars = Keyword.get(opts, :content_chars, 100_000)

    with :ok <- validate_ids(ids),
         :ok <- validate_cap(opts),
         true <- is_integer(chars) and chars >= 1 and chars <= 1_000_000,
         {:ok, data} <-
           api(
             :post,
             "/contents",
             Map.merge(params(opts), %{"ids" => ids, "text" => %{"maxCharacters" => chars}}),
             opts
           ),
         {:ok, data} <- store_contents(data, opts),
         {:ok, meta} <- snapshot(data, "contents", opts),
         {:ok, result} <- compact_results(data, meta, opts, true) do
      {:ok,
       Map.put(
         result,
         :provider_notice,
         "Text requested with maxCharacters: #{chars}; Exa may truncate or fail individual URLs. Inspect statuses in read(result_id)."
       )}
    else
      false -> HTTP.error(:invalid_options, "content_chars must be 1..1000000.")
      error -> error
    end
  end

  @doc "Grounded answer plus source citations, with bounded display."
  def answer(query, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_answer(query, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_answer(query, opts) do
    with :ok <- validate_query(query),
         :ok <- validate_cap(opts),
         {:ok, data} <-
           api(
             :post,
             "/answer",
             Map.merge(params(opts), %{"query" => query, "stream" => false, "text" => false}),
             opts
           ),
         {:ok, meta} <- snapshot(data, "answer", opts) do
      cap = Keyword.get(opts, :max_bytes, 12_000)
      answer = data["answer"] || data["output"] || ""
      text = if is_binary(answer), do: answer, else: Jason.encode!(answer)
      shown = Store.clip(text, div(cap, 2))
      sources = data["citations"] || []
      {citations, cut} = bounded_results(sources, cap - byte_size(shown), false)

      {:ok,
       Map.merge(metadata(data, meta), %{
         answer: shown,
         citations: citations,
         truncated: cut or shown != text,
         notice: notice(cut or shown != text, meta.id)
       })}
    end
  end

  @doc "Page the full cached Exa JSON response without a paid network request."
  def read(id, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_read(id, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_read(id, opts), do: Store.read(id, opts)
  @doc "Submit an asynchronous Exa Agent run and start an independent watcher."
  def research(query, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_research(query, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_research(query, opts), do: Research.start(query, opts)
  @doc "Read persisted local research state (never polls Exa)."
  def research_status(job, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_research_status(job, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_research_status(job, opts), do: Research.status(job, opts)
  @doc "Resume watching a persisted run after node/worker restart; no resubmission."
  def resume_research(job, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_resume_research(job, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_resume_research(job, opts), do: Research.resume(job, opts)
  @doc "Acknowledge completion and stop repeated named-agent event delivery."
  def ack_research(job, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_ack_research(job, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_ack_research(job, opts), do: Research.ack(job, opts)
  @doc "Explicitly cancel a remote run; the service may already have incurred costs."
  def cancel_research(job, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: do_cancel_research(job, opts),
      else: HTTP.error(:invalid_options, "Options must be a keyword list.")
  end

  defp do_cancel_research(job, opts), do: Research.cancel(job, opts)

  @doc false
  def api(method, path, body, opts) do
    settings = Keyword.get(opts, :settings, &Nano.Settings.get/1)
    base = Keyword.get(opts, :base_url, "https://api.exa.ai")

    try do
      key = settings.("EXA_API_KEY")

      with :ok <- validate_base(base),
           :ok <- validate_key(key),
           {:ok, resp} <-
             HTTP.request(
               method,
               String.trim_trailing(base, "/") <> path,
               [{"x-api-key", key}, {"content-type", "application/json"}],
               if(body == nil, do: nil, else: Jason.encode!(body)),
               Keyword.put(opts, :redirect, false)
             ) do
        if resp.status in 200..299 do
          case Jason.decode(resp.body) do
            {:ok, data} when is_map(data) ->
              with :ok <- validate_response(path, data) do
                {:ok, Map.put_new(data, "requestId", HTTP.header(resp, "x-request-id"))}
              end

            _ ->
              HTTP.error(
                :invalid_response,
                "Exa returned invalid JSON; retry or check the base URL."
              )
          end
        else
          reason =
            case resp.status do
              401 -> :unauthorized
              403 -> :forbidden
              402 -> :quota
              429 -> :rate_limited
              _ -> :http
            end

          {:error,
           %{
             reason: reason,
             status: resp.status,
             retry_after: bounded_header(HTTP.header(resp, "retry-after")),
             request_id: bounded_header(HTTP.header(resp, "x-request-id")),
             message:
               "Exa HTTP #{resp.status}; check key/quota/request parameters, or wait and retry. No automatic paid retry was made."
           }}
        end
      end
    rescue
      _ ->
        HTTP.error(
          :invalid_options,
          "Cannot read settings or encode Exa parameters; check the per-call options."
        )
    end
  end

  @doc false
  def snapshot(data, kind, opts),
    do:
      Store.put(
        Jason.encode!(data, pretty: true),
        %{url: "https://api.exa.ai/" <> kind, title: "Exa " <> kind, source: "exa"},
        opts
      )

  defp store_contents(data, opts) do
    Enum.reduce_while(data["results"], {:ok, []}, fn result, {:ok, acc} ->
      if is_binary(result["text"]) do
        meta = %{
          url: result["url"] || result["id"] || "",
          title: result["title"] || "",
          source: "exa-text"
        }

        case Store.put(result["text"], meta, opts) do
          {:ok, stored} -> {:cont, {:ok, [Map.put(result, "content_id", stored.id) | acc]}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, [result | acc]}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Map.put(data, "results", Enum.reverse(results))}
      error -> error
    end
  end

  defp validate_response(path, data) do
    list_key =
      case path do
        "/search" -> "results"
        "/contents" -> "results"
        "/answer" -> "citations"
        _ -> nil
      end

    if list_key do
      results = Map.get(data, list_key)

      valid =
        is_list(results) and
          Enum.all?(results, fn result ->
            is_map(result) and is_list(result["highlights"] || []) and
              Enum.all?(["id", "title", "url", "text"], fn key ->
                is_nil(result[key]) or is_binary(result[key])
              end)
          end)

      valid = valid and (path != "/answer" or Map.has_key?(data, "answer"))

      if valid,
        do: :ok,
        else:
          HTTP.error(
            :invalid_response,
            "Exa returned malformed results/citations; check provider docs and retry."
          )
    else
      :ok
    end
  end

  defp compact_results(data, meta, opts, text?) do
    {results, cut} =
      bounded_results(data["results"] || [], Keyword.get(opts, :max_bytes, 12_000), text?)

    {:ok,
     Map.merge(metadata(data, meta), %{
       results: results,
       total_results: length(data["results"] || []),
       truncated: cut,
       notice: notice(cut, meta.id)
     })}
  end

  defp bounded_results(results, cap, text?) when is_list(results) do
    {items, _bytes, cut} =
      Enum.reduce(Enum.with_index(results, 1), {[], 2, false}, fn {result, index},
                                                                  {acc, bytes, cut} ->
        {item, clipped} = normalize(result, text?)
        item = Map.put(item, :index, index)
        {item, fitted} = fit_text(item, cap - bytes)
        clipped = clipped or fitted
        size = byte_size(Jason.encode!(item)) + 1

        if bytes + size <= cap,
          do: {[item | acc], bytes + size, cut or clipped},
          else: {acc, bytes, true}
      end)

    {Enum.reverse(items), cut}
  end

  defp bounded_results(_, _, _), do: {[], true}

  defp fit_text(%{text: text} = item, budget) do
    overhead = byte_size(Jason.encode!(Map.delete(item, :text))) + 12
    shown = Store.clip(text, max(0, budget - overhead))
    fitted = Map.put(item, :text, shown)

    if byte_size(Jason.encode!(fitted)) + 1 > budget,
      do: {Map.put(fitted, :text, ""), true},
      else: {fitted, shown != text}
  end

  defp fit_text(item, _), do: {item, false}

  defp normalize(result, text?) when is_map(result) do
    fields = [{"id", 1500}, {"title", 300}, {"url", 1500}, {"publishedDate", 100}]
    fields = if text?, do: fields ++ [{"text", 6000}, {"content_id", 64}], else: fields

    {map, cut} =
      Enum.reduce(fields, {%{}, false}, fn {key, cap}, {acc, cut} ->
        value = result[key]

        if is_binary(value) do
          shown = Store.clip(value, cap)
          {Map.put(acc, key_to_atom(key), shown), cut or shown != value}
        else
          {acc, cut}
        end
      end)

    highlights = Enum.filter(result["highlights"] || [], &is_binary/1)
    shown = highlights |> Enum.take(3) |> Enum.map(&Store.clip(&1, 800))
    {Map.put(map, :highlights, shown), cut or shown != highlights}
  end

  defp normalize(_, _), do: {%{}, true}
  defp key_to_atom("publishedDate"), do: :published_date
  defp key_to_atom("id"), do: :id
  defp key_to_atom("title"), do: :title
  defp key_to_atom("url"), do: :url
  defp key_to_atom("text"), do: :text
  defp key_to_atom("content_id"), do: :content_id

  defp metadata(data, meta) do
    %{
      result_id: meta.id,
      request_id: bounded_header(data["requestId"]),
      cost_dollars: bound_value(data["costDollars"]),
      source: "exa",
      stored_bytes: meta.bytes
    }
  end

  defp bound_value(value) do
    if byte_size(Jason.encode!(value)) <= 1000,
      do: value,
      else: %{notice: "Usage metadata too large; inspect full cached response."}
  end

  defp notice(true, id),
    do: "Results/fields cut. Full response: Seedling.Search.read(#{inspect(id)}, offset: 0)."

  defp notice(false, _), do: nil
  defp bounded_header(value) when is_binary(value), do: Store.clip(value, 200)
  defp bounded_header(_), do: nil

  @doc false
  def params(opts), do: Keyword.get(opts, :params, %{})
  @doc false
  def validate_query(query) do
    if is_binary(query) and String.valid?(query) and String.trim(query) != "" and
         byte_size(query) <= 20_000,
       do: :ok,
       else:
         HTTP.error(
           :invalid_query,
           "Query must be a nonempty UTF-8 string of at most 20000 bytes."
         )
  end

  defp validate_limit(limit) do
    if is_integer(limit) and limit in 1..100,
      do: :ok,
      else: HTTP.error(:invalid_options, "limit must be 1..100.")
  end

  defp validate_ids(ids) do
    if is_list(ids) and length(ids) in 1..100 and
         Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..2048)),
       do: :ok,
       else:
         HTTP.error(
           :invalid_ids,
           "Pass a list of 1..100 URL/document id strings, each 1..2048 bytes."
         )
  end

  @doc false
  def validate_cap(opts) do
    cap = Keyword.get(opts, :max_bytes, 12_000)

    if is_integer(cap) and cap in 4..40_000 and is_map(params(opts)),
      do: Store.options(opts),
      else: HTTP.error(:invalid_options, "max_bytes must be 4..40000 and params must be a map.")
  end

  defp validate_key(key) do
    if is_binary(key) and String.trim(key) != "",
      do: :ok,
      else:
        HTTP.error(
          :missing_key,
          "EXA_API_KEY is not set; ask the operator to add it to Nano.Settings."
        )
  end

  defp validate_base(base), do: Seedling.Web.validate_url(base)
end
