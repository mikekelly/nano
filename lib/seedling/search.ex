defmodule Seedling.Search do
  @moduledoc """
  Real Exa search, page contents, grounded answers and asynchronous research from eval.
  The key is read from `Nano.Settings.get("EXA_API_KEY")` without exposing it. With no
  key every service operation returns `{:error, %{kind: :missing_key}}` (no scraping).

      Seedling.Search.search("Elixir OTP supervision")
      Seedling.Search.contents(["https://elixir-lang.org/getting-started/mix-otp/introduction-to-mix.html"])
      Seedling.Search.answer("What does an OTP supervisor do?")
      {:ok, run} = Seedling.Search.research("Explain OTP supervision with sources", effort: "minimal")
      # Later mailbox event: %{event: :seedling_research, run_id: ..., result: ...}
      Seedling.Search.research_read(run.run_id)

  Search returns up to five compact title/highlight/id results; contents returns
  cache ids, not full text. `Seedling.Web.read(id)` pages stored content. Research
  uses the current Exa Agent API (`/agent/runs`) and a background polling process,
  not an eval-sized wait. After a node restart call `watch(run_id)` to resume.
  See `docs/web-search.md` for costs, citations, limits and tested support.
  """
  alias Seedling.Web.{Store, Transport}
  @terminal ["completed", "failed", "cancelled"]
  @base "https://api.exa.ai"

  def configured?, do: match?({:ok, _}, key([]))

  def search(query, opts \\ []) do
    with :ok <- query(query) do
      n = Keyword.get(opts, :num_results, 5)

      if is_integer(n) and n in 1..10 do
        payload = %{
          "query" => query,
          "numResults" => n,
          "type" => Keyword.get(opts, :type, "auto"),
          "contents" => %{"text" => false, "highlights" => %{"maxCharacters" => 600}}
        }

        payload = Map.merge(Keyword.get(opts, :params, %{}), payload)

        with {:ok, data} <- api(:post, "/search", payload, opts),
             results when is_list(results) <- data["results"] do
          {:ok,
           %{
             results: Enum.take(results, n) |> Enum.map(&compact/1),
             request_id: bounded(data["requestId"], 200),
             note: "Use contents([result.id]) or Web.fetch(result.url) for full passages"
           }}
        else
          {:error, _} = error -> error
          _ -> {:error, %{kind: :invalid_response}}
        end
      else
        {:error, %{kind: :invalid_limit, max: 10}}
      end
    end
  end

  @doc "Fetch Exa contents for URL/result ids (at most 10); return metadata and cache ids only."
  def contents(ids, opts \\ []) do
    cap = Keyword.get(opts, :content_characters, 30000)

    if is_integer(cap) and cap in 1..1_000_000 and is_list(ids) and length(ids) in 1..10 and
         Enum.all?(ids, &(is_binary(&1) and byte_size(&1) <= 4000)) do
      payload =
        Map.merge(Keyword.get(opts, :params, %{}), %{
          "ids" => ids,
          "text" => %{"maxCharacters" => cap}
        })

      with {:ok, data} <- api(:post, "/contents", payload, opts),
           results when is_list(results) <- data["results"],
           true <- Enum.all?(results, &is_map/1) do
        pages =
          Enum.take(results, 10)
          |> Enum.map(fn result ->
            text = result["text"] || ""

            if is_binary(text) and text != "" do
              case Store.put(
                     "exa:" <> (bounded(result["id"], 4000) || bounded(result["url"], 4000) || ""),
                     text,
                     %{
                       "url" => result["url"],
                       "title" => result["title"],
                       "source" => "exa",
                       "content_truncated" => String.length(text) >= cap
                     },
                     opts
                   ) do
                {:ok, rec} ->
                  Map.merge(compact(result), %{
                    cache_id: rec["id"],
                    characters: String.length(text),
                    content_truncated: rec["content_truncated"]
                  })

                error ->
                  error
              end
            else
              %{
                id: bounded(result["id"], 1000),
                url: bounded(result["url"], 1000),
                error: :no_content
              }
            end
          end)

        {:ok,
         %{
           results: pages,
           statuses: compact_statuses(data["statuses"]),
           request_id: bounded(data["requestId"], 200)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, %{kind: :invalid_response}}
      end
    else
      {:error, %{kind: :invalid_ids, hint: "Pass 1..10 URL or Exa result-id strings"}}
    end
  end

  def answer(query, opts \\ []) do
    with :ok <- query(query),
         payload =
           Map.merge(Keyword.get(opts, :params, %{}), %{
             "query" => query,
             "text" => false,
             "stream" => false
           }),
         {:ok, data} <- api(:post, "/answer", payload, opts),
         {:ok, rec} <-
           Store.put("answer:" <> query, Jason.encode!(data), %{"source" => "exa_answer"}, opts) do
      answer =
        if is_binary(data["answer"]), do: data["answer"], else: Jason.encode!(data["answer"])

      {:ok,
       %{
         answer: Store.clip(answer, 8000),
         truncated: byte_size(answer) > 8000,
         citations:
           Enum.take(if(is_list(data["citations"]), do: data["citations"], else: []), 10)
           |> Enum.map(&compact/1),
         cache_id: rec["id"],
         note: "Grounded service answer; check citations. Full JSON is cached."
       }}
    end
  end

  @doc "Create a real Exa Agent run, then notify :notify (default eval's owning agent/task caller) on terminal completion."
  def research(query, opts \\ []) do
    with :ok <- query(query),
         payload =
           Map.merge(Keyword.get(opts, :params, %{}), %{
             "query" => query,
             "effort" => Keyword.get(opts, :effort, "minimal")
           }),
         payload =
           if(Keyword.has_key?(opts, :output_schema),
             do: Map.put(payload, "outputSchema", opts[:output_schema]),
             else: payload
           ),
         {:ok, run} <- api(:post, "/agent/runs", payload, opts),
         :ok <- run_id(run["id"]),
         {:ok, _} <- save_run(run, opts) do
      watch_run(run["id"], run, opts)
    end
  end

  @doc "Resume watching an existing service run, e.g. after node restart. Does not create another paid run."
  def watch(id, opts \\ []) do
    with :ok <- run_id(id), {:ok, _} <- key(opts), do: watch_run(id, nil, opts)
  end

  @doc "Fetch a compact service status once. A watcher normally handles this for you."
  def research_status(id, opts \\ []) do
    with :ok <- run_id(id),
         {:ok, run} <- api(:get, "/agent/runs/" <> id, nil, opts),
         {:ok, rec} <- save_run(run, opts),
         do: {:ok, summary(run, rec)}
  end

  def research_read(id, opts \\ []) do
    with :ok <- run_id(id),
         {:ok, rec} <- Store.get(Store.id("research:" <> id), opts),
         do: Store.page(rec, opts)
  end

  @doc "Cancel the service run, not just a local watcher. May incur costs for work already done."
  def cancel(id, opts \\ []) do
    with :ok <- run_id(id),
         {:ok, run} <- api(:post, "/agent/runs/" <> id <> "/cancel", %{}, opts),
         {:ok, rec} <- save_run(run, opts),
         do: {:ok, summary(run, rec)}
  end

  defp watch_run(id, initial, opts) do
    with {:ok, owner} <- Seedling.Web.Owner.resolve(Keyword.get(opts, :notify)) do
      pid =
        spawn(fn ->
          monitor = Seedling.Web.Owner.monitor(owner)
          deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :max_wait, 900_000)
          poll(id, initial, owner, monitor, deadline, opts)
        end)

      {:ok,
       %{
         run_id: id,
         worker: pid,
         status: if(initial, do: initial["status"], else: "watching"),
         cache_id: Store.id("research:" <> id)
       }}
    end
  end

  defp poll(id, initial, owner, monitor, deadline, opts) do
    interval = Keyword.get(opts, :poll_interval, 3000)

    receive do
      {:DOWN, ^monitor, :process, _, _} when monitor != nil -> :ok
    after
      interval ->
        cond do
          System.monotonic_time(:millisecond) >= deadline ->
            notify(
              owner,
              id,
              {:error,
               %{
                 kind: :research_timeout,
                 hint:
                   "Service run may still be running; watch(run_id) to resume or cancel(run_id)"
               }}
            )

          true ->
            result =
              if initial && initial["status"] in @terminal,
                do: {:ok, initial},
                else: api(:get, "/agent/runs/" <> id, nil, opts)

            case result do
              {:ok, run} ->
                case save_run(run, opts) do
                  {:ok, rec} ->
                    if run["status"] in @terminal do
                      notify(owner, id, {:ok, summary(run, rec)})
                    else
                      poll(id, nil, owner, monitor, deadline, opts)
                    end

                  error ->
                    notify(owner, id, error)
                end

              {:error, %{kind: kind} = error}
              when kind in [:network, :timeout, :rate_limited, :service_unavailable] ->
                retry = max(interval, min(Map.get(error, :retry_after_ms, interval), 30000))
                poll(id, nil, owner, monitor, deadline, Keyword.put(opts, :poll_interval, retry))

              error ->
                notify(owner, id, error)
            end
        end
    end
  rescue
    _ -> notify(owner, id, {:error, %{kind: :research_worker}})
  end

  defp notify(owner, id, result),
    do:
      Seedling.Web.Owner.deliver(
        owner,
        %{event: :seedling_research, run_id: id, result: result, sender_pid: self()},
        []
      )

  defp save_run(run, opts) do
    with :ok <- run_id(run["id"]) do
      Store.put(
        "research:" <> run["id"],
        Jason.encode!(run),
        %{"source" => "exa_research", "title" => "Exa research " <> run["id"]},
        opts
      )
    end
  end

  defp summary(run, rec),
    do: %{
      run_id: run["id"],
      status: run["status"],
      stop_reason: run["stopReason"],
      cache_id: rec["id"],
      cost_dollars:
        numeric_fields(run["costDollars"], [
          "total",
          "agentCompute",
          "search",
          "emails",
          "phoneNumbers"
        ]),
      usage:
        numeric_fields(run["usage"], ["agentComputeUnits", "searches", "emails", "phoneNumbers"])
    }

  defp numeric_fields(map, keys) when is_map(map),
    do: map |> Map.take(keys) |> Enum.filter(fn {_, value} -> is_number(value) end) |> Map.new()

  defp numeric_fields(_, _), do: nil

  defp api(method, path, payload, opts) do
    with {:ok, key} <- key(opts),
         base = Keyword.get(opts, :base_url, @base),
         :ok <- Transport.url(base),
         {:ok, response} <-
           Transport.request(
             method,
             String.trim_trailing(base, "/") <> path,
             payload,
             Keyword.merge(opts,
               headers: [{"x-api-key", key}, {"accept", "application/json"}],
               redirect: false
             )
           ) do
      case response.status do
        status when status in 200..299 ->
          case Jason.decode(response.body) do
            {:ok, data} when is_map(data) -> {:ok, data}
            _ -> {:error, %{kind: :invalid_response}}
          end

        status ->
          kind =
            case status do
              401 -> :unauthorized
              402 -> :payment_required
              403 -> :forbidden
              429 -> :rate_limited
              n when n >= 500 -> :service_unavailable
              _ -> :http
            end

          retry =
            case response.headers["retry-after"] do
              [value | _] ->
                case Integer.parse(value) do
                  {n, ""} when n >= 0 -> min(n * 1000, 30000)
                  _ -> 3000
                end

              _ ->
                3000
            end

          {:error, %{kind: kind, status: status, retry_after_ms: retry}}
      end
    end
  end

  defp key(opts) do
    key =
      if Keyword.has_key?(opts, :api_key),
        do: opts[:api_key],
        else: Nano.Settings.get("EXA_API_KEY")

    if is_binary(key) and String.trim(key) != "",
      do: {:ok, key},
      else: {:error, %{kind: :missing_key, setting: "EXA_API_KEY"}}
  end

  defp query(q) when is_binary(q) and byte_size(q) in 1..10000,
    do: if(String.trim(q) == "", do: {:error, %{kind: :invalid_query}}, else: :ok)

  defp query(_), do: {:error, %{kind: :invalid_query}}

  defp run_id(id) when is_binary(id) and byte_size(id) in 1..200 do
    if Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, id),
      do: :ok,
      else: {:error, %{kind: :invalid_run_id}}
  end

  defp run_id(_), do: {:error, %{kind: :invalid_run_id}}

  defp compact(result) when is_map(result) do
    highlights = if is_list(result["highlights"]), do: result["highlights"], else: []
    fields = [{"id", 1000}, {"url", 1000}, {"title", 300}, {"publishedDate", 100}]

    clipped =
      Enum.any?(fields, fn {key, cap} ->
        is_binary(result[key]) and byte_size(result[key]) > cap
      end)

    %{
      id: bounded(result["id"], 1000),
      url: bounded(result["url"], 1000),
      title: bounded(result["title"], 300),
      published_date: bounded(result["publishedDate"], 100),
      highlights: Enum.take(highlights, 2) |> Enum.map(&bounded(&1, 500)),
      truncated:
        clipped or length(highlights) > 2 or
          Enum.any?(highlights, &(is_binary(&1) and byte_size(&1) > 500))
    }
  end

  defp compact(_), do: %{error: :invalid_result}

  defp compact_statuses(statuses) when is_list(statuses),
    do:
      Enum.take(statuses, 10)
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn s ->
        %{"id" => bounded(s["id"], 1000), "status" => bounded(s["status"], 50)}
      end)

  defp compact_statuses(_), do: []
  defp bounded(text, bytes) when is_binary(text), do: Store.clip(text, bytes)
  defp bounded(_, _), do: nil
end
