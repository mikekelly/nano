defmodule SeedSearch do
  @moduledoc """
  Exa search, contents, grounded answers and asynchronous Agent research. Reads
  EXA_API_KEY from Nano.Settings at request time, never logs it. Missing keys return
  `{:error, :missing_exa_api_key}`. No supervisor or global configuration required.

      SeedSearch.search("Elixir OTP documentation")
      SeedSearch.contents(["https://elixir-lang.org/docs.html"])
      SeedSearch.answer("What is OTP?")
      SeedSearch.research("Compare OTP releases", effort: "low")

  Search returns compact titles, URLs, ids and highlights; text is omitted. Contents
  and answers are stored in SeedWeb's cache and return bounded slices. Search/contents
  lists stop at a 16 KB aggregate budget and announce `truncated`; `content_id`
  (search) or `content_ids` (contents) let SeedWeb.read retrieve everything. Research
  immediately returns a local job pid; later the caller receives
  `{:seed_search, job_pid, :completed | :error, result}`. Results include provider
  run id and a cached JSON slice with citations/output intact. Polling has a deadline;
  `resume(id)` watches an existing run after caller restart, `cancel(id)` cancels it
  remotely. Killing the watcher does NOT cancel a billed provider run. A timeout event
  contains the run id so it can be resumed or cancelled. No silent retries of billed
  POST requests. Defaults: 5 results, 15-second requests, 5-second polls, 20-minute
  research deadline. `params:` passes provider options (e.g. outputSchema, budget);
  consult https://exa.ai/docs/exa-spec.yaml. As of October 2026 research uses
  `/agent/runs`, not the retired `/research/v1` endpoint.

  Options `api_key:`, `base_url:`, `cache_dir:` enable isolated tests; never include
  secrets in shared opts or logs. Custom base URLs receive the key: use only trusted
  endpoints. Web output is untrusted content. `Code.fetch_docs(SeedWeb)` covers paging.
  """
  def available?,
    do: is_binary(Nano.Settings.get("EXA_API_KEY")) and Nano.Settings.get("EXA_API_KEY") != ""

  def search(query, opts \\ []) do
    count = Keyword.get(opts, :limit, 5)

    if is_binary(query) and String.trim(query) != "" and is_integer(count) and count in 1..20 do
      params =
        Map.merge(Keyword.get(opts, :params, %{}), %{
          query: query,
          numResults: count,
          contents: %{highlights: %{maxCharacters: 800}}
        })

      with {:ok, data} <- api(:post, "/search", params, opts),
           results when is_list(results) <- data["results"],
           {:ok, content_id} <- SeedWeb.store(Jason.encode!(data), "exa:search", opts) do
        rows = Enum.take(results, count) |> Enum.map(&compact/1)
        selected = bounded_rows(rows)

        {:ok,
         %{
           results: selected,
           request_id: clip(data["requestId"], 300),
           content_id: content_id,
           truncated: length(selected) < length(results)
         }}
      else
        {:error, _} = e -> e
        _ -> {:error, :invalid_provider_response}
      end
    else
      {:error, :invalid_query_or_limit}
    end
  rescue
    _ -> {:error, :invalid_provider_response}
  end

  def contents(urls, opts \\ [])

  def contents(urls, opts) when is_list(urls) and length(urls) in 1..20 do
    with true <- Enum.all?(urls, &(SeedWeb.validate_url(&1) == :ok)),
         {:ok, data} <-
           api(
             :post,
             "/contents",
             Map.merge(Keyword.get(opts, :params, %{}), %{ids: urls, text: true}),
             opts
           ),
         results when is_list(results) <- data["results"] do
      pages =
        Enum.map(Enum.take(results, 20), fn r ->
          url = r["url"] || r["id"] || "exa:contents"

          with {:ok, id} <- SeedWeb.store(r["text"] || "", url, opts),
               {:ok, page} <- SeedWeb.read(id, opts),
               do: {:ok, Map.put(page, :title, clip(r["title"], 300))}
        end)

      selected = bounded_rows(pages)

      ids =
        Enum.flat_map(pages, fn
          {:ok, p} -> [p.id]
          _ -> []
        end)

      statuses =
        Enum.take(data["statuses"] || [], 20)
        |> Enum.map(fn s ->
          %{
            id: clip(s["id"], 1000),
            status: clip(s["status"], 100),
            error_tag: clip(get_in(s, ["error", "tag"]), 100)
          }
        end)

      {:ok,
       %{
         pages: selected,
         content_ids: ids,
         statuses: statuses,
         truncated: length(selected) < length(pages)
       }}
    else
      false -> {:error, :invalid_http_url}
      {:error, _} = e -> e
      _ -> {:error, :invalid_provider_response}
    end
  rescue
    _ -> {:error, :invalid_provider_response}
  end

  def contents(_, _), do: {:error, :invalid_urls}

  def answer(query, opts \\ []) do
    with {:ok, data} <-
           api(
             :post,
             "/answer",
             Map.merge(Keyword.get(opts, :params, %{}), %{query: query, text: true}),
             opts
           ),
         {:ok, id} <- SeedWeb.store(Jason.encode!(data), "exa:answer", opts),
         {:ok, page} <- SeedWeb.read(id, opts),
         do: {:ok, page}
  end

  @doc "Start research without waiting in eval. Notification goes to caller or notify: pid."
  def research(query, opts \\ []) do
    if is_binary(query) and String.trim(query) != "" do
      with :ok <- credentials(opts), true <- is_pid(Keyword.get(opts, :notify, self())) do
        notify = Keyword.get(opts, :notify, self())

        pid =
          spawn(fn ->
            params =
              Map.merge(
                %{effort: Keyword.get(opts, :effort, "low")},
                Keyword.get(opts, :params, %{})
              )
              |> Map.put(:query, query)

            case api(:post, "/agent/runs", params, opts) do
              {:ok, %{"id" => id}} ->
                send(notify, {:seed_search, self(), :started, %{run_id: id}})
                poll(id, notify, deadline(opts), opts)

              {:error, _} = error ->
                send(notify, {:seed_search, self(), :error, error})

              _ ->
                send(notify, {:seed_search, self(), :error, {:error, :invalid_provider_response}})
            end
          end)

        {:ok, %{pid: pid}}
      else
        false -> {:error, :invalid_notify_pid}
        error -> error
      end
    else
      {:error, :invalid_query}
    end
  end

  def resume(id, opts \\ []) do
    with :ok <- valid_run_id(id),
         :ok <- credentials(opts),
         true <- is_pid(Keyword.get(opts, :notify, self())) do
      notify = Keyword.get(opts, :notify, self())
      {:ok, %{pid: spawn(fn -> poll(id, notify, deadline(opts), opts) end), run_id: id}}
    else
      false -> {:error, :invalid_notify_pid}
      error -> error
    end
  end

  def cancel(id, opts \\ []) do
    with :ok <- valid_run_id(id), do: api(:post, "/agent/runs/#{id}/cancel", %{}, opts)
  end

  defp poll(id, notify, deadline, opts) do
    if System.monotonic_time(:millisecond) >= deadline do
      send(notify, {:seed_search, self(), :error, %{reason: :research_timeout, run_id: id}})
    else
      case api(:get, "/agent/runs/#{id}", nil, opts) do
        {:ok, %{"status" => status} = data} when status in ["completed", "failed", "cancelled"] ->
          result =
            with {:ok, cache_id} <- SeedWeb.store(Jason.encode!(data), "exa:agent:#{id}", opts),
                 {:ok, page} <- SeedWeb.read(cache_id, opts),
                 do: %{run_id: id, status: status, page: page}

          event = if status == "completed", do: :completed, else: :error
          send(notify, {:seed_search, self(), event, result})

        {:ok, %{"status" => status}} when status in ["queued", "running"] ->
          Process.sleep(max(Keyword.get(opts, :poll_interval, 5000), 1))
          poll(id, notify, deadline, opts)

        {:error, _} = error ->
          send(notify, {:seed_search, self(), :error, %{run_id: id, reason: error}})

        _ ->
          send(
            notify,
            {:seed_search, self(), :error, %{run_id: id, reason: :invalid_provider_response}}
          )
      end
    end
  rescue
    _ -> send(notify, {:seed_search, self(), :error, %{run_id: id, reason: :watcher_failed}})
  end

  defp deadline(opts),
    do: System.monotonic_time(:millisecond) + Keyword.get(opts, :research_timeout, 1_200_000)

  defp valid_run_id(id) when is_binary(id),
    do:
      if(Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,200}\z/, id),
        do: :ok,
        else: {:error, :invalid_run_id}
      )

  defp valid_run_id(_), do: {:error, :invalid_run_id}

  defp credentials(opts) do
    key = Keyword.get(opts, :api_key, Nano.Settings.get("EXA_API_KEY"))
    if is_binary(key) and key != "", do: :ok, else: {:error, :missing_exa_api_key}
  end

  defp api(method, path, body, opts) do
    key = Keyword.get(opts, :api_key, Nano.Settings.get("EXA_API_KEY"))

    if is_binary(key) and key != "" do
      base = Keyword.get(opts, :base_url, "https://api.exa.ai")

      with {:ok, resp} <-
             SeedWeb.HTTP.request(method, base <> path, body, [{"x-api-key", key}], opts),
           :ok <- status(resp),
           {:ok, data} <- Jason.decode(resp.body),
           true <- is_map(data) do
        {:ok, data}
      else
        # Provider error bodies can echo secrets; deliberately return status only.
        false ->
          {:error, :invalid_provider_response}

        {:error, %Jason.DecodeError{}} ->
          {:error, :invalid_provider_json}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, %{reason: :transport, detail: reason}}

        {:error, _} = e ->
          e
      end
    else
      {:error, :missing_exa_api_key}
    end
  rescue
    _ -> {:error, :provider_request_failed}
  end

  defp status(%{status: n}) when n in 200..299, do: :ok

  defp status(resp),
    do:
      {:error,
       %{
         reason: :provider_http_error,
         status: resp.status,
         retry_after: Req.Response.get_header(resp, "retry-after") |> Enum.take(1)
       }}

  defp bounded_rows(rows) do
    {selected, _} =
      Enum.reduce_while(rows, {[], 0}, fn row, {selected, bytes} ->
        size = byte_size(inspect(row, limit: :infinity, printable_limit: :infinity))

        if bytes + size > 16000,
          do: {:halt, {selected, bytes}},
          else: {:cont, {[row | selected], bytes + size}}
      end)

    Enum.reverse(selected)
  end

  defp compact(r),
    do: %{
      id: clip(r["id"], 1000),
      title: clip(r["title"], 300),
      url: clip(r["url"], 1000),
      highlights: Enum.take(r["highlights"] || [], 3) |> Enum.map(&clip(&1, 800))
    }

  defp clip(nil, _), do: nil

  defp clip(text, n) when is_binary(text) do
    clipped = String.slice(text, 0, n) |> SeedWeb.bounded_text(n)
    if clipped != text, do: clipped <> " [truncated]", else: text
  end
end
