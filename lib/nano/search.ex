defmodule Nano.Search do
  @moduledoc """
  Exa search, contents, grounded answers and asynchronous research (current Agent API).
  `search(query)` returns compact results; `contents(urls)` stores text for Nano.Web.read/2.
  `research(query)` returns immediately and sends `{:nano_research, ref, result}` later.
  No key returns `{:error, :missing_api_key}`. See docs/nova-web.md.
  """
  def search(query, opts \\ []) do
    body = %{
      "query" => query,
      "numResults" => min(Keyword.get(opts, :limit, 5), 20),
      "contents" => %{"highlights" => %{"maxCharacters" => 1000}}
    }

    with {:ok, response} <-
           request(:post, "/search", Map.merge(body, Keyword.get(opts, :params, %{})), opts) do
      {:ok,
       %{
         results: Enum.map(Enum.take(response["results"] || [], 10), &compact/1),
         request_id: response["requestId"]
       }}
    end
  end

  def contents(urls, opts \\ []) do
    with {:ok, response} <-
           request(
             :post,
             "/contents",
             %{"urls" => List.wrap(urls), "text" => %{"maxCharacters" => 200_000}},
             opts
           ) do
      results =
        Enum.map(Enum.take(response["results"] || [], 10), fn r ->
          case Nano.Web.store(
                 r["url"] || r["id"],
                 r["text"] || "",
                 Keyword.put(opts, :title, r["title"])
               ) do
            {:ok, page} -> Map.put(compact(r), :page, page)
            error -> %{id: r["id"], error: error}
          end
        end)

      {:ok, %{results: results, statuses: response["statuses"]}}
    end
  end

  def answer(query, opts \\ []) do
    with {:ok, response} <-
           request(
             :post,
             "/answer",
             Map.merge(%{"query" => query, "text" => false}, Keyword.get(opts, :params, %{})),
             opts
           ) do
      {:ok,
       %{
         answer: String.slice(response["answer"] || "", 0, 12_000),
         citations: Enum.map(Enum.take(response["citations"] || [], 10), &compact/1)
       }}
    end
  end

  @doc "Start a background run. Options: notify pid, poll_interval ms, research_timeout ms, params map (effort/outputSchema)."
  def research(query, opts \\ []) do
    if key(opts) in [nil, ""] do
      {:error, :missing_api_key}
    else
      recipient = Keyword.get(opts, :notify, default_recipient())

      if is_pid(recipient) or is_binary(recipient) do
        ref = make_ref()

        pid =
          spawn(fn ->
            result =
              try do
                with {:ok, run} <-
                       request(
                         :post,
                         "/agent/runs",
                         Map.merge(%{"query" => query}, Keyword.get(opts, :params, %{})),
                         opts
                       ),
                     id when is_binary(id) <- run["id"] do
                  notify(recipient, {:nano_research_started, ref, id}, opts)

                  poll(
                    id,
                    opts,
                    System.monotonic_time(:millisecond) +
                      Keyword.get(opts, :research_timeout, 900_000)
                  )
                else
                  nil -> {:error, :missing_run_id}
                  error -> error
                end
              rescue
                _ -> {:error, :research_worker_failed}
              catch
                _, _ -> {:error, :research_worker_failed}
              end

            notify(recipient, {:nano_research, ref, result}, opts)
          end)

        {:ok, %{ref: ref, pid: pid}}
      else
        {:error, :invalid_notify}
      end
    end
  end

  defp default_recipient do
    Enum.find_value([self() | List.wrap(Process.get(:"$callers"))], fn pid ->
      try do
        Enum.find_value(Registry.keys(Nano.Registry, pid), fn
          {:agent, name} -> name
          _ -> nil
        end)
      rescue
        _ -> nil
      end
    end) || self()
  end

  defp notify(target, message, opts) when is_binary(target) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :notify_timeout, 30_000)
    notify_name(target, message, deadline)
  end

  defp notify(pid, message, _opts) when is_pid(pid), do: send(pid, message)

  defp notify_name(name, message, deadline) do
    case NanoAgent.whereis(name) do
      pid when is_pid(pid) ->
        send(pid, message)

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          notify_name(name, message, deadline)
        else
          :undelivered
        end
    end
  end

  def research_status(id, opts \\ []),
    do: request(:get, "/agent/runs/" <> URI.encode(id, &URI.char_unreserved?/1), nil, opts)

  defp poll(id, opts, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, %{reason: :research_timeout, id: id}}
    else
      case research_status(id, opts) do
        {:ok, %{"status" => status} = run}
        when status in ["completed", "failed", "canceled", "cancelled"] ->
          if status == "completed",
            do: persist_run(run, opts),
            else: {:error, %{reason: status, id: id}}

        {:ok, _} ->
          Process.sleep(Keyword.get(opts, :poll_interval, 3000))
          poll(id, opts, deadline)

        error ->
          error
      end
    end
  end

  defp persist_run(run, opts) do
    with {:ok, page} <-
           Nano.Web.store(
             "https://api.exa.ai/agent/runs/" <> run["id"],
             Jason.encode!(run, pretty: true),
             opts
           ),
         do: {:ok, %{id: run["id"], status: run["status"], page: page}}
  end

  defp compact(r),
    do: %{
      id: r["id"],
      url: r["url"],
      title: cut(r["title"], 300),
      highlights: Enum.map(Enum.take(r["highlights"] || [], 2), &cut(&1, 500)),
      published_date: r["publishedDate"]
    }

  defp cut(nil, _), do: nil
  defp cut(s, n), do: String.slice(s, 0, n)
  defp key(opts), do: Keyword.get(opts, :api_key, System.get_env("EXA_API_KEY"))

  defp request(method, path, body, opts) do
    if key(opts) in [nil, ""] do
      {:error, :missing_api_key}
    else
      request =
        [
          method: method,
          url: Keyword.get(opts, :base_url, "https://api.exa.ai") <> path,
          headers: [{"x-api-key", key(opts)}],
          receive_timeout: Keyword.get(opts, :timeout, 20_000),
          connect_options: [timeout: 5000],
          retry: false
        ] ++ Keyword.get(opts, :req_options, [])

      request = if body, do: Keyword.put(request, :json, body), else: request

      case Req.request(request) do
        {:ok, %{status: s, body: b}} when s in 200..299 and is_map(b) -> {:ok, b}
        {:ok, %{status: s, headers: h}} -> {:error, %{status: s, retry_after: h["retry-after"]}}
        {:error, _} -> {:error, :network_error}
        _ -> {:error, :invalid_response}
      end
    end
  rescue
    _ -> {:error, :request_failed}
  end
end
