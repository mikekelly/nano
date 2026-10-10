defmodule Nano.Search do
  @moduledoc """
  Exa search, contents, cited answers and asynchronous Agent research.
  Key comes from Nano.Settings EXA_API_KEY, never returned or persisted.
  `search(query)` returns compact titles, URLs, IDs and highlights (10 default,
  50 maximum). `contents(urls)` and `answer(query)` persist full cited JSON.
  Results are bounded text with cut/bytes/result handle; `read(result, offset: 1)`
  pages complete JSON via Nano.Tools. `evidence(query)` returns excerpts, not a verdict.

  `research(query, owner: "alice")` returns immediately. An independent worker
  creates a current Exa `/agent/runs` job, polls and delivers
  `{:research, local_id, summary}` to the stable name, waiting if absent.
  Results/status persist; `status(handle)` detects interrupted workers and
  `resume(handle, owner: name)` resumes a saved remote ID. Creation is not retried
  (duplicate billing risk). Crash during creation may leave an orphan remote job.
  Delivery is at-most-once; status/read recover missed events. Local timeout does
  not cancel billed remote work; use `cancel(handle)`. Default effort minimal.
  Pass Exa parameters via `params: %{}`; auto/ultra require explicit budget.
  Provider grounding is retained, not independently verified. Disk results have
  no retention policy: delete returned directories when no longer needed.

  Options: max_bytes 100..30000 (12000 default), timeout 1..20000 ms (15000),
  retries 0..3 (2), dir storage parent. Research: owner required, poll_interval
  10..60000 ms (2000), research_timeout up to 3 hours (15 min), delivery_timeout
  up to 24 hours (one hour). Test transport fn method,path,body returns
  {:ok, status, headers, body}; never receives the key. Example:

      Nano.Search.search("Elixir supervision")
      Nano.Search.research("Explain OTP with citations", owner: "alice")
  """
  def search(query, opts \\ []) do
    safe(fn ->
      query!(query)
      n = bound(opts[:num_results] || 10, 1, 50)

      body =
        Map.merge(opts[:params] || %{}, %{
          "query" => query,
          "numResults" => n,
          "contents" => %{"highlights" => %{"maxCharacters" => 1000}}
        })

      with {:ok, data} <- request(:post, "/search", body, opts) do
        results =
          Enum.take(data["results"] || [], n)
          |> Enum.map(
            &Map.take(
              &1,
              ["id", "url", "title", "score", "publishedDate", "highlights"]
            )
          )

        compact(Map.put(data, "results", results), opts)
      end
    end)
  end

  def contents(urls, opts \\ []) do
    safe(fn ->
      unless is_list(urls) and length(urls) in 1..20 and Enum.all?(urls, &is_binary/1),
        do: raise(ArgumentError)

      with {:ok, data} <-
             request(
               :post,
               "/contents",
               Map.merge(%{"text" => %{"maxCharacters" => 30000}}, opts[:params] || %{})
               |> Map.put("urls", urls),
               opts
             ),
           do: compact(data, opts)
    end)
  end

  def answer(query, opts \\ []) do
    safe(fn ->
      query!(query)

      with {:ok, data} <-
             request(:post, "/answer", Map.merge(opts[:params] || %{}, %{"query" => query}), opts),
           do: compact(data, opts)
    end)
  end

  def evidence(query, opts \\ []), do: search(query, opts)
  def read(%{dir: dir}, opts \\ []), do: Nano.Tools.read(Path.join(dir, "result.json"), opts)

  def research(query, opts \\ []) do
    safe(fn ->
      query!(query)
      owner = owner!(opts)
      validate_worker_opts(opts)
      dir = new_dir(opts)
      handle = %{id: Path.basename(dir), dir: dir, owner: owner}

      params =
        Map.merge(%{"effort" => "minimal"}, opts[:params] || %{}) |> Map.put("query", query)

      save(dir, %{status: :starting, owner: owner, remote_id: nil, pid: nil})
      caller = self()
      ref = make_ref()

      pid =
        spawn(fn ->
          receive do
            ^ref ->
              result =
                with {:ok, run} <-
                       request(:post, "/agent/runs", params, Keyword.put(opts, :retries, 0)),
                     true <- is_binary(run["id"]) do
                  save(dir, %{status: :running, owner: owner, remote_id: run["id"], pid: self()})
                  poll(run, opts, deadline(opts))
                else
                  {:error, e} -> {:error, e}
                  _ -> {:error, %{kind: :invalid_response}}
                end

              finish(handle, result, opts)
          after
            5000 -> send(caller, {:research_start_failed, handle.id})
          end
        end)

      save(dir, %{status: :starting, owner: owner, remote_id: nil, pid: pid})
      send(pid, ref)
      {:ok, Map.put(handle, :pid, pid)}
    end)
  end

  def status(%{dir: dir}) do
    safe(fn ->
      with {:ok, bytes} <- File.read(Path.join(dir, "status.term")) do
        s = :erlang.binary_to_term(bytes, [:safe])

        s =
          if s.status in [:starting, :running] and
               (not is_pid(s[:pid]) or not Process.alive?(s.pid)),
             do: Map.put(s, :status, :interrupted),
             else: s

        {:ok, s}
      end
    end)
  end

  def resume(%{dir: dir} = handle, opts \\ []) do
    safe(fn ->
      owner = owner!(opts)
      validate_worker_opts(opts)

      with {:ok, s} <- status(handle),
           true <- s.status == :interrupted and is_binary(s.remote_id) do
        pid =
          spawn(fn ->
            save(dir, %{s | status: :running, owner: owner, pid: self()})

            result =
              with {:ok, run} <- request(:get, run_path(s.remote_id), nil, opts),
                   do: poll(run, opts, deadline(opts))

            finish(%{handle | owner: owner}, result, opts)
          end)

        {:ok, Map.put(handle, :pid, pid)}
      else
        _ -> {:error, %{kind: :not_resumable}}
      end
    end)
  end

  def cancel(handle, opts \\ []) do
    safe(fn ->
      with {:ok, %{remote_id: id}} when is_binary(id) <- status(handle),
           do: request(:post, run_path(id) <> "/cancel", %{}, opts)
    end)
  end

  defp run_path(id), do: "/agent/runs/" <> URI.encode(id, &URI.char_unreserved?/1)

  defp poll(run, opts, until) do
    cond do
      run["status"] in ["completed", "failed", "cancelled"] ->
        {:ok, run}

      System.monotonic_time(:millisecond) >= until ->
        {:error, %{kind: :research_timeout, remote_id: run["id"]}}

      true ->
        Process.sleep(opts[:poll_interval] || 2000)

        with {:ok, next} <- request(:get, run_path(run["id"]), nil, opts),
             do: poll(next, opts, until)
    end
  end

  defp finish(handle, result, opts) do
    {:ok, previous} = status(handle)

    summary =
      case result do
        {:ok, run} ->
          case compact(run, Keyword.put(opts, :result_dir, handle.dir)) do
            {:ok, bounded} -> %{status: run["status"], result: bounded, remote_id: run["id"]}
            {:error, error} -> %{status: :error, error: error, remote_id: previous.remote_id}
          end

        {:error, error} ->
          %{status: :error, error: error, remote_id: previous.remote_id}
      end

    save(handle.dir, Map.merge(previous, summary))

    deliver(
      handle.owner,
      {:research, handle.id, summary},
      System.monotonic_time(:millisecond) + (opts[:delivery_timeout] || 3_600_000)
    )
  end

  defp deliver(owner, event, until) do
    case NanoAgent.whereis(owner) do
      pid when is_pid(pid) ->
        NanoAgent.notify(owner, event)

      _ ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(100)
          deliver(owner, event, until)
        end
    end
  end

  defp deadline(opts),
    do: System.monotonic_time(:millisecond) + (opts[:research_timeout] || 900_000)

  defp validate_worker_opts(opts) do
    bound(opts[:poll_interval] || 2000, 10, 60000)
    bound(opts[:research_timeout] || 900_000, 10, 10_800_000)
    bound(opts[:delivery_timeout] || 3_600_000, 10, 86_400_000)
    bound(opts[:max_bytes] || 12000, 100, 30000)
  end

  defp owner!(opts) do
    owner = opts[:owner]
    unless is_binary(owner) and owner =~ ~r/^[\w.-]+$/, do: raise(ArgumentError)
    owner
  end

  defp request(method, path, body, opts) do
    retries = bound(opts[:retries] || 2, 0, 3)
    timeout = bound(opts[:timeout] || 15000, 1, 20000)
    task = Task.async(fn -> attempt(method, path, body, opts, retries) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, %{kind: :timeout}}
    end
  end

  defp attempt(method, path, body, opts, retries) do
    response =
      if opts[:transport] do
        opts[:transport].(method, path, body)
      else
        key = Nano.Settings.get("EXA_API_KEY")

        if is_binary(key) and key != "" do
          req_opts = [
            method: method,
            url: "https://api.exa.ai" <> path,
            headers: [{"x-api-key", key}],
            receive_timeout: bound(opts[:timeout] || 15000, 1, 20000),
            connect_options: [timeout: 5000],
            retry: false,
            redirect: false
          ]

          req_opts = if body, do: Keyword.put(req_opts, :json, body), else: req_opts

          case Req.request(req_opts) do
            {:ok, r} -> {:ok, r.status, r.headers, r.body}
            {:error, _} -> {:error, %{kind: :transport}}
          end
        else
          {:error, %{kind: :missing_key, message: "EXA_API_KEY is not set"}}
        end
      end

    case response do
      {:ok, status, _, data} when status in 200..299 and is_map(data) ->
        {:ok, data}

      {:ok, status, headers, _} when (status == 429 or status >= 500) and retries > 0 ->
        Process.sleep(retry_delay(headers, retries))
        attempt(method, path, body, opts, retries - 1)

      {:ok, status, _, _} ->
        {:error, %{kind: :http, status: status}}

      {:error, %{kind: :missing_key}} ->
        {:error, %{kind: :missing_key, message: "EXA_API_KEY is not set"}}

      {:error, _} when retries > 0 ->
        Process.sleep((4 - retries) * 100)
        attempt(method, path, body, opts, retries - 1)

      {:error, _} ->
        {:error, %{kind: :transport}}

      _ ->
        {:error, %{kind: :invalid_response}}
    end
  rescue
    _ -> {:error, %{kind: :transport}}
  catch
    _, _ -> {:error, %{kind: :transport}}
  end

  defp retry_delay(headers, retries) do
    value = if is_map(headers), do: List.wrap(headers["retry-after"]) |> List.first(), else: nil

    case Integer.parse(value || "") do
      {seconds, ""} -> min(max(seconds * 1000, 0), 2000)
      _ -> (4 - retries) * 200
    end
  end

  defp compact(data, opts) do
    safe(fn ->
      dir = opts[:result_dir] || new_dir(opts)
      json = Jason.encode!(data, pretty: true)
      if byte_size(json) > 5_000_000, do: raise(ArgumentError)
      :ok = File.write(Path.join(dir, "result.json"), json)
      max = bound(opts[:max_bytes] || 12000, 100, 30000)

      {:ok,
       %{
         text: prefix(json, max),
         cut: byte_size(json) > max,
         bytes: byte_size(json),
         result: %{dir: dir},
         continuation:
           if(byte_size(json) > max,
             do: "Nano.Search.read(result, offset: 1, limit: 100)",
             else: nil
           )
       }}
    end)
  end

  defp prefix(text, n) when byte_size(text) <= n, do: text

  defp prefix(text, n) do
    part = binary_part(text, 0, n)
    if String.valid?(part), do: part, else: prefix(text, n - 1)
  end

  defp new_dir(opts) do
    parent =
      opts[:dir] || Path.join(Application.get_env(:nano, :spill_dir, "/tmp/nano"), "search")

    dir = Path.join(parent, Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
    File.mkdir_p!(dir)
    dir
  end

  defp save(dir, s) do
    tmp = Path.join(dir, "status.tmp")
    File.write!(tmp, :erlang.term_to_binary(s))
    File.rename!(tmp, Path.join(dir, "status.term"))
  end

  defp bound(n, low, high) when is_integer(n) and n >= low and n <= high, do: n
  defp bound(_, _, _), do: raise(ArgumentError)

  defp query!(q),
    do:
      if(not is_binary(q) or String.trim(q) == "" or byte_size(q) > 20000,
        do: raise(ArgumentError)
      )

  defp safe(fun) do
    fun.()
  rescue
    _ ->
      {:error,
       %{kind: :invalid_argument_or_storage, message: "Check arguments and storage permissions"}}
  catch
    _, _ -> {:error, %{kind: :failed}}
  end
end
