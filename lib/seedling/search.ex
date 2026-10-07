defmodule Seedling.Search do
  @moduledoc """
  Exa search, contents, cited answers and asynchronous research. Errors are values.
  `search/2` returns compact string-keyed provider results; `contents/2` fetches text.
  `research/2` requires `notify: pid_or_agent_name` and emits
  `{:search_research_done, id, result}`. See `seedings/SEARCH_USAGE.md`.
  """
  @type result :: {:ok, map()} | {:error, map()}
  @spec search(String.t(), keyword()) :: result()
  def search(query, opts \\ []) do
    safely(fn ->
      n = Keyword.get(opts, :num_results, 5)

      if is_binary(query) and query != "" and is_integer(n) and n in 1..20 do
        body = %{
          "query" => query,
          "numResults" => n,
          "type" => Keyword.get(opts, :type, "auto"),
          "contents" => %{"highlights" => %{"maxCharacters" => 1000}}
        }

        body = Map.merge(Keyword.get(opts, :params, %{}), body)

        with {:ok, data} <- request(:post, "/search", body, opts),
             do: compact_results(data, false)
      else
        error(:invalid_argument)
      end
    end)
  end

  @spec contents([String.t()], keyword()) :: result()
  def contents(urls, opts \\ []) do
    safely(fn ->
      if is_list(urls) and length(urls) in 1..20 and Enum.all?(urls, &is_binary/1) do
        body = %{"ids" => urls, "text" => %{"maxCharacters" => 12000}}

        with {:ok, data} <- request(:post, "/contents", body, opts),
             do: compact_results(data, true)
      else
        error(:invalid_argument)
      end
    end)
  end

  @spec answer(String.t(), keyword()) :: result()
  def answer(query, opts \\ []) do
    safely(fn ->
      if is_binary(query) and query != "" do
        with {:ok, data} <- request(:post, "/answer", %{"query" => query, "text" => false}, opts) do
          {:ok, Map.take(data, ["answer", "citations", "requestId", "costDollars"]) |> bounded()}
        end
      else
        error(:invalid_argument)
      end
    end)
  end

  @doc "Starts a fixed-cost minimal-effort run by default; persists id before polling."
  def research(query, opts \\ []) do
    safely(fn ->
      with :ok <- validate_notify(opts),
           true <- is_binary(query) and query != "",
           {:ok, run} <- request(:post, "/agent/runs", research_body(query, opts), opts),
           id when is_binary(id) <- run["id"] do
        watch(id, opts)
      else
        {:error, _} = err -> err
        _ -> error(:invalid_argument_or_response)
      end
    end)
  end

  @doc "Resume polling a provider run after a node restart; requires notify again."
  def resume(id, opts \\ []) do
    safely(fn ->
      with :ok <- validate_notify(opts), true <- valid_id?(id) do
        watch(id, opts)
      else
        {:error, _} = err -> err
        _ -> error(:invalid_id)
      end
    end)
  end

  def research_status(id, opts \\ []) do
    safely(fn ->
      if valid_id?(id),
        do: request(:get, "/agent/runs/" <> id, nil, opts),
        else: error(:invalid_id)
    end)
  end

  def cancel_research(id, opts \\ []) do
    safely(fn ->
      if valid_id?(id),
        do: request(:post, "/agent/runs/" <> id <> "/cancel", %{}, opts),
        else: error(:invalid_id)
    end)
  end

  defp research_body(query, opts) do
    %{"query" => query, "effort" => Keyword.get(opts, :effort, "minimal")}
    |> maybe_put("outputSchema", Keyword.get(opts, :schema))
    |> maybe_put("budget", Keyword.get(opts, :budget))
  end

  defp maybe_put(map, _, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp watch(id, opts) do
    if valid_id?(id) do
      dir = Keyword.get(opts, :state_dir, "/data/seedling/search")
      path = Path.join(dir, id <> ".json")

      with :ok <- File.mkdir_p(dir),
           :ok <-
             persist(path, %{
               "id" => id,
               "status" => "watching",
               "notify" => inspect(opts[:notify])
             }) do
        worker =
          spawn(fn ->
            result =
              safely(fn ->
                poll(
                  id,
                  opts,
                  System.monotonic_time(:millisecond) + Keyword.get(opts, :poll_timeout, 600_000)
                )
              end)

            saved = persist(path, %{"id" => id, "result" => result_json(result)})

            event_result =
              case saved do
                :ok ->
                  case result do
                    {:ok, data} -> {:ok, %{id: id, path: path, data: bounded(data)}}
                    err -> err
                  end

                _ ->
                  error(:persistence_failed)
              end

            deliver(opts[:notify], {:search_research_done, id, event_result}, 60)
          end)

        {:ok, %{id: id, worker: worker, path: path}}
      else
        _ -> error(:persistence_failed)
      end
    else
      error(:invalid_id)
    end
  end

  defp poll(id, opts, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      error(:poll_timeout)
    else
      case research_status(id, opts) do
        {:ok, %{"status" => "completed"} = data} ->
          {:ok, data}

        {:ok, %{"status" => status}} when status in ["failed", "cancelled"] ->
          {:error, %{kind: :research_failed, status: status}}

        {:ok, %{"status" => status}} when status in ["queued", "running", "pending"] ->
          Process.sleep(Keyword.get(opts, :poll_interval, 4000))
          poll(id, opts, deadline)

        {:error, %{status: status}} when status in [429, 500, 502, 503, 504] ->
          Process.sleep(Keyword.get(opts, :poll_interval, 4000))
          poll(id, opts, deadline)

        {:error, _} = err ->
          err

        _ ->
          error(:invalid_response)
      end
    end
  end

  defp deliver(pid, event, _) when is_pid(pid), do: send(pid, event)

  defp deliver(name, event, retries) when is_binary(name) do
    case NanoAgent.whereis(name) do
      pid when is_pid(pid) ->
        send(pid, event)

      _ when retries > 0 ->
        Process.sleep(1000)
        deliver(name, event, retries - 1)

      _ ->
        :unavailable
    end
  end

  defp validate_notify(opts) do
    if is_pid(opts[:notify]) or (is_binary(opts[:notify]) and opts[:notify] != ""),
      do: :ok,
      else: error(:notify_required)
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,200}\z/, id)

  defp persist(path, data) do
    tmp = path <> "." <> Integer.to_string(System.unique_integer([:positive])) <> ".tmp"
    with :ok <- File.write(tmp, Jason.encode!(data)), do: File.rename(tmp, path)
  end

  defp result_json({:ok, data}), do: %{"ok" => data}
  defp result_json({:error, err}), do: %{"error" => err}

  defp compact_results(data, text?) do
    keys =
      ["id", "url", "title", "highlights", "publishedDate", "author"] ++
        if(text?, do: ["text"], else: [])

    if is_list(data["results"]) and Enum.all?(data["results"], &is_map/1) do
      {:ok,
       Map.take(data, ["requestId", "costDollars", "statuses"])
       |> Map.put("results", Enum.take(data["results"], 20) |> Enum.map(&Map.take(&1, keys)))
       |> bounded()}
    else
      error(:invalid_response)
    end
  end

  # Bound every public text response even if the provider ignores requested limits.
  defp bounded(data) do
    {value, _remaining, clipped} = clip(data, 20000)
    if clipped and is_map(value), do: Map.put(value, "_truncated", true), else: value
  end

  defp clip(value, budget) when is_binary(value) do
    size = min(byte_size(value), max(budget, 0))
    text = utf8_prefix(binary_part(value, 0, size))
    {text, budget - size, size < byte_size(value)}
  end

  defp clip(value, budget) when is_list(value) do
    {list, {left, clipped}} =
      Enum.map_reduce(Enum.take(value, 100), {budget, length(value) > 100}, fn v, {b, c} ->
        {v, b, c2} = clip(v, b)
        {v, {b, c or c2}}
      end)

    {list, left, clipped}
  end

  defp clip(value, budget) when is_map(value) do
    {pairs, {left, clipped}} =
      Enum.map_reduce(Enum.take(value, 100), {budget, map_size(value) > 100}, fn {k, v}, {b, c} ->
        {v, b, c2} = clip(v, b)
        {{k, v}, {b, c or c2}}
      end)

    {Map.new(pairs), left, clipped}
  end

  defp clip(value, budget), do: {value, budget, false}
  defp utf8_prefix(""), do: ""

  defp utf8_prefix(text) do
    if String.valid?(text), do: text, else: utf8_prefix(binary_part(text, 0, byte_size(text) - 1))
  end

  defp request(method, path, body, opts) do
    key = Keyword.get(opts, :api_key, System.get_env("EXA_API_KEY"))

    cond do
      not is_binary(key) or key == "" ->
        error(:missing_api_key)

      true ->
        req_opts = [
          method: method,
          url: Keyword.get(opts, :base_url, "https://api.exa.ai") <> path,
          headers: [{"x-api-key", key}],
          receive_timeout: Keyword.get(opts, :timeout, 30_000),
          retry: false,
          redirect: false
        ]

        req_opts = if body, do: Keyword.put(req_opts, :json, body), else: req_opts

        response =
          case opts[:transport] do
            fun when is_function(fun, 1) -> fun.(req_opts)
            nil -> Req.request(req_opts)
          end

        case response do
          {:ok, %{status: status, body: data}} when status in 200..299 and is_map(data) ->
            {:ok, data}

          {:ok, %{status: status}} ->
            {:error, %{kind: :http, status: status}}

          {:error, _} ->
            error(:transport)

          _ ->
            error(:invalid_response)
        end
    end
  end

  defp error(kind), do: {:error, %{kind: kind}}

  defp safely(fun) do
    fun.()
  rescue
    _ -> error(:invalid_argument_or_transport)
  catch
    _, _ -> error(:transport)
  end
end
