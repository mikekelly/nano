defmodule Vega.Search do
  @moduledoc """
  Exa search, content, cited answers, and asynchronous Exa Agent research.
  Credentials are read on demand from `Nano.Settings.get("EXA_API_KEY")`.
  `search(query)` returns bounded titles/highlights/URLs, never full page text.
  `contents(urls)` persists content for `Vega.Web.read/2`; `answer(query)` preserves citations.
  `research(query)` starts a service run plus a detached watcher; completion arrives as a mailbox event.
  See docs/vega-web-search.md, including research cost and restart limits.
  """
  alias Vega.Web.Cache

  def search(query, opts \\ []) when is_binary(query) do
    n = min(max(Keyword.get(opts, :num_results, 5), 1), 10)

    payload =
      Map.merge(Keyword.get(opts, :params, %{}), %{
        "query" => query,
        "numResults" => n,
        "type" => Keyword.get(opts, :type, "auto"),
        "contents" => %{"highlights" => %{"maxCharacters" => 1000}}
      })

    with {:ok, body} <- api(:post, "/search", payload, opts) do
      {:ok,
       %{
         results: Enum.take(body["results"] || [], n) |> Enum.map(&slim/1),
         request_id: body["requestId"],
         cost: body["costDollars"]
       }}
    end
  rescue
    _ -> {:error, :invalid_search_response}
  end

  defp slim(r) do
    %{
      id: clip(r["id"], 500),
      url: clip(r["url"], 500),
      title: String.slice(r["title"] || "", 0, 300),
      published_date: r["publishedDate"],
      highlights: Enum.take(r["highlights"] || [], 2) |> Enum.map(&String.slice(&1, 0, 1000))
    }
  end

  defp clip(nil, _), do: nil
  defp clip(text, n) when is_binary(text), do: String.slice(text, 0, n)

  def contents(urls, opts \\ []) when is_list(urls) do
    if length(urls) in 1..10 and Enum.all?(urls, &(Vega.Web.validate_url(&1) == :ok)) do
      with {:ok, body} <-
             api(
               :post,
               "/contents",
               %{"urls" => urls, "text" => %{"maxCharacters" => 100_000}},
               opts
             ) do
        results =
          Enum.take(body["results"] || [], 10)
          |> Enum.map(fn r ->
            case Cache.put(
                   r["url"] || r["id"],
                   r["text"] || "",
                   %{url: r["url"], title: r["title"], method: "exa"},
                   opts
                 ) do
              {:ok, id} -> Map.merge(slim(r), %{content_id: id})
              {:error, reason} -> %{url: r["url"], error: reason}
            end
          end)

        {:ok,
         %{
           results: results,
           statuses:
             Enum.take(body["statuses"] || [], 10)
             |> Enum.map(fn r -> %{id: clip(r["id"], 500), status: clip(r["status"], 100)} end)
         }}
      end
    else
      {:error, :invalid_urls}
    end
  rescue
    _ -> {:error, :invalid_contents_response}
  end

  def answer(query, opts \\ []) when is_binary(query) do
    with {:ok, body} <- api(:post, "/answer", %{"query" => query, "text" => false}, opts),
         {:ok, id} <-
           Cache.put("answer:" <> query, Jason.encode!(body), %{method: "exa-answer"}, opts) do
      {:ok,
       %{
         answer: String.slice(body["answer"] || "", 0, 8000),
         citations:
           Enum.take(body["citations"] || [], 10)
           |> Enum.map(fn r -> slim(r) |> Map.put(:highlights, []) end),
         content_id: id,
         cost: body["costDollars"]
       }}
    end
  rescue
    _ -> {:error, :invalid_answer_response}
  end

  @doc "Start a paid Exa Agent run; effort defaults low. Completion arrives as {:vega_research, result}."
  def research(query, opts \\ []) when is_binary(query) do
    payload =
      Map.merge(Keyword.get(opts, :params, %{}), %{
        "query" => query,
        "effort" => Keyword.get(opts, :effort, "low")
      })

    payload =
      if schema = Keyword.get(opts, :output_schema),
        do: Map.put(payload, "outputSchema", schema),
        else: payload

    with {:ok, run} <- api(:post, "/agent/runs", payload, opts),
         id when is_binary(id) <- run["id"] do
      case watch(id, opts) do
        {:ok, task} ->
          {:ok, %{run_id: id, task: task, status: run["status"]}}

        error ->
          {:error,
           %{run_id: id, watcher_error: error, recovery: "Call Vega.Search.watch(run_id)"}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_research_response}
    end
  end

  @doc "Resume watching a known Exa Agent run. Completion: {:vega_research, result}."
  def watch(id, opts \\ []) when is_binary(id) do
    notify = Keyword.get(opts, :notify, self())
    agent = Keyword.get_lazy(opts, :agent, fn -> infer_agent() end)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :research_timeout, 600_000)

    pid =
      spawn(fn ->
        if leader = Process.whereis(:user), do: Process.group_leader(self(), leader)

        result =
          try do
            await_run(id, opts, deadline)
          rescue
            _ -> {:error, %{run_id: id, reason: :watch_failed}}
          catch
            _, _ -> {:error, %{run_id: id, reason: :watch_failed}}
          end

        deliver(
          agent,
          notify,
          {:vega_research, result},
          System.monotonic_time(:millisecond) + Keyword.get(opts, :delivery_timeout, 600_000)
        )
      end)

    {:ok, %{pid: pid, run_id: id, content_id: Cache.id("research:" <> id)}}
  rescue
    _ -> {:error, :watch_failed}
  end

  defp infer_agent do
    callers = [self() | Process.get(:"$callers", [])]
    Enum.find(NanoAgent.list(), fn name -> NanoAgent.whereis(name) in callers end)
  rescue
    _ -> nil
  end

  defp deliver(nil, notify, event, _deadline) do
    if is_pid(notify) and Process.alive?(notify), do: send(notify, event)
    :ok
  end

  defp deliver(agent, notify, event, deadline) do
    cond do
      is_pid(NanoAgent.whereis(agent)) ->
        NanoAgent.notify(agent, event)

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(250)
        deliver(agent, notify, event, deadline)
    end
  end

  @doc "Stop a local watcher; does not cancel the paid remote run (use cancel/2)."
  def stop_watching(%{pid: pid}) when is_pid(pid), do: Process.exit(pid, :kill)

  defp await_run(id, opts, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, %{run_id: id, reason: :research_timeout}}
    else
      case raw_status(id, opts) do
        {:ok, %{"status" => "completed"} = run} ->
          store_run(run, opts)

        {:ok, %{"status" => s}} when s in ["failed", "cancelled"] ->
          {:error, %{run_id: id, status: s, reason: :service_failed}}

        {:ok, _} ->
          Process.sleep(Keyword.get(opts, :poll_interval, 4000))
          await_run(id, opts, deadline)

        {:error, _} = err ->
          err
      end
    end
  end

  defp store_run(run, opts) do
    with {:ok, id} <-
           Cache.put(
             "research:" <> run["id"],
             Jason.encode!(run),
             %{method: "exa-research"},
             opts
           ) do
      output = run["output"] || %{}

      {:ok,
       %{
         run_id: run["id"],
         status: run["status"],
         content_id: id,
         text: String.slice(output["text"] || "", 0, 8000),
         # Grounding can be arbitrarily large and schema-dependent: exact output persists in cache.
         grounding_preview: Jason.encode!(output["grounding"]) |> String.slice(0, 4000),
         cost: run["costDollars"]
       }}
    end
  end

  defp raw_status(id, opts),
    do: api(:get, "/agent/runs/" <> URI.encode(id, &URI.char_unreserved?/1), nil, opts)

  @doc "Bounded service status; completed output is persisted and available by content_id."
  def status(id, opts \\ []) do
    with {:ok, run} <- raw_status(id, opts) do
      if run["status"] == "completed" do
        store_run(run, opts)
      else
        {:ok, %{run_id: run["id"], status: run["status"], cost: run["costDollars"]}}
      end
    end
  end

  def cancel(id, opts \\ []),
    do:
      api(
        :post,
        "/agent/runs/" <> URI.encode(id, &URI.char_unreserved?/1) <> "/cancel",
        %{},
        opts
      )

  @doc false
  def api(method, path, payload, opts) do
    key = Keyword.get_lazy(opts, :api_key, fn -> Nano.Settings.get("EXA_API_KEY") end)

    if not is_binary(key) or key == "" do
      {:error, :missing_exa_api_key}
    else
      base = Keyword.get(opts, :base_url, "https://api.exa.ai")

      request_opts =
        Keyword.take(opts, [:timeout, :max_bytes]) ++
          [headers: [{"x-api-key", key}], redirect: false]

      request_opts = if payload, do: request_opts ++ [json: payload], else: request_opts

      case Vega.Web.request(method, base <> path, request_opts) do
        {:ok, %{status: s, body: body}} when s in 200..299 ->
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> {:ok, map}
            _ -> {:error, :invalid_json}
          end

        {:ok, %{status: s} = response} ->
          # Deliberately omit server error bodies: some gateways echo credentials/requests.
          {:error,
           %{
             service: :exa,
             status: s,
             retry_after: Req.Response.get_header(response, "retry-after") |> List.first()
           }}

        {:error, _} = error ->
          error
      end
    end
  rescue
    _ -> {:error, :exa_request_failed}
  end
end
