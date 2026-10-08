defmodule Seedling.Search.Research do
  @moduledoc false
  alias Seedling.{Files, Search}
  alias Seedling.Web.{HTTP, Store}

  def start(query, opts) do
    effort = Keyword.get(opts, :effort, "low")
    notify = Keyword.get(opts, :notify, self())

    with :ok <- Search.validate_query(query),
         :ok <- Search.validate_cap(opts),
         :ok <- validate_options(effort, notify, opts),
         {:ok, run} <- Search.api(:post, "/agent/runs", body(query, effort, opts), opts),
         :ok <- valid_id(run["id"]) do
      handle = %{
        id: run["id"],
        jobs_dir: dir(opts),
        cache_dir: Store.root(opts),
        status: run["status"] || "queued",
        notify_agent: agent_name(notify),
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case save(handle) do
        :ok ->
          launch(handle, Keyword.put(opts, :notify, notify))
          {:ok, handle}

        {:error, issue} ->
          {:error,
           Map.merge(issue, %{
             job: handle,
             message:
               "Exa run was created, but local persistence failed. Keep the returned job id and explicitly cancel or recover after fixing jobs_dir."
           })}
      end
    end
  end

  def status(job, opts) do
    with {:ok, handle} <- handle(job, opts),
         {:ok, raw} <- File.read(path(handle)),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, data}
    else
      {:error, %{reason: _}} = error ->
        error

      _ ->
        HTTP.error(
          :missing_job,
          "No persisted research record; use the original handle and jobs_dir."
        )
    end
  end

  def resume(job, opts) do
    with {:ok, stored} <- load_or_restore(job, opts),
         {:ok, handle} <- handle(job, opts),
         :ok <-
           Search.validate_cap(
             Keyword.put_new(opts, :cache_dir, stored["cache_dir"] || Store.root(opts))
           ),
         :ok <- validate_options("low", recipient(stored, opts), opts) do
      opts = Keyword.put_new(opts, :cache_dir, stored["cache_dir"] || Store.root(opts))

      merged =
        Map.merge(handle, %{notify_agent: stored["notify_agent"], cache_dir: Store.root(opts)})

      stop_watcher(handle)

      if stored["status"] == "error" do
        File.rm(path(handle) <> ".ack")
        save(Map.merge(merged, %{status: "queued", local_complete: false}))
      end

      launch(merged, Keyword.put(opts, :notify, recipient(stored, opts)))

      {:ok, merged}
    end
  end

  defp load_or_restore(job, opts) do
    case status(job, opts) do
      {:error, %{reason: :missing_job}} ->
        with {:ok, handle} <- handle(job, opts),
             :ok <- Search.validate_cap(opts) do
          cache_dir = Keyword.get(opts, :cache_dir, field(job, :cache_dir) || Store.root(opts))
          notify_agent = field(job, :notify_agent)

          stored =
            Map.merge(handle, %{
              cache_dir: cache_dir,
              notify_agent: notify_agent,
              status: "queued",
              local_complete: false,
              recovered: true
            })

          notify = recipient(stringify(stored), opts)

          with :ok <- Search.validate_cap(Keyword.put(opts, :cache_dir, cache_dir)),
               :ok <- validate_options("low", notify, opts),
               :ok <- save(stored) do
            {:ok, stringify(stored)}
          end
        end

      result ->
        result
    end
  end

  defp field(job, key) when is_map(job),
    do: Map.get(job, key) || Map.get(job, Atom.to_string(key))

  defp field(_, _), do: nil

  def ack(job, opts) do
    with {:ok, handle} <- handle(job, opts),
         {:ok, _} <- Files.write(path(handle) <> ".ack", "acknowledged\n") do
      {:ok, %{id: handle.id, acknowledged: true}}
    end
  end

  def cancel(job, opts) do
    with {:ok, handle} <- handle(job, opts),
         {:ok, _} <-
           Search.api(:post, "/agent/runs/" <> URI.encode(handle.id) <> "/cancel", %{}, opts) do
      {:ok, %{id: handle.id, cancellation_requested: true}}
    end
  end

  defp body(query, effort, opts) do
    base = Map.merge(Search.params(opts), %{"query" => query, "effort" => effort})
    if opts[:output_schema], do: Map.put(base, "outputSchema", opts[:output_schema]), else: base
  end

  defp stop_watcher(handle) do
    case :global.whereis_name({__MODULE__, Path.expand(handle.jobs_dir), handle.id}) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} ->
            :global.unregister_name({__MODULE__, Path.expand(handle.jobs_dir), handle.id})
        end

      _ ->
        :ok
    end
  end

  defp launch(handle, opts) do
    spawn(fn ->
      name = {__MODULE__, Path.expand(handle.jobs_dir), handle.id}

      if :global.register_name(name, self()) == :yes do
        try do
          case status(handle, opts) do
            {:ok, %{"local_complete" => true} = record} -> notify(handle, record, opts)
            _ -> poll(handle, opts, System.monotonic_time(:millisecond))
          end
        rescue
          _ ->
            finish_error(
              handle,
              :worker_failed,
              "Research watcher failed; resume_research/2 can recover the run.",
              opts
            )
        after
          :global.unregister_name(name)
        end
      end
    end)
  end

  defp poll(handle, opts, started) do
    elapsed = System.monotonic_time(:millisecond) - started
    deadline = Keyword.get(opts, :research_timeout, 600_000)

    if elapsed >= deadline do
      finish_error(
        handle,
        :timed_out,
        "Local watching deadline exceeded; remote run may still incur costs. Resume watching or explicitly cancel.",
        opts
      )
    else
      request_opts =
        Keyword.put(opts, :timeout, min(Keyword.get(opts, :timeout, 20_000), deadline - elapsed))

      case Search.api(:get, "/agent/runs/" <> URI.encode(handle.id), nil, request_opts) do
        {:ok, %{"status" => status} = run} when status in ["completed", "failed", "cancelled"] ->
          case Search.snapshot(run, "agent/runs/" <> handle.id, opts) do
            {:ok, snapshot} ->
              complete =
                Map.merge(handle, %{
                  status: status,
                  local_complete: true,
                  result_id: snapshot.id,
                  completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
                  cost_dollars: bounded_usage(run["costDollars"]),
                  usage: bounded_usage(run["usage"])
                })

              persist_and_notify(handle, complete, opts)

            {:error, _} ->
              finish_error(
                handle,
                :storage,
                "Cannot store research result; free disk space and resume watching.",
                opts
              )
          end

        {:ok, %{"status" => status}} when status in ["queued", "running"] ->
          save(Map.merge(handle, %{status: status, local_complete: false}))
          Process.sleep(min(Keyword.get(opts, :poll_interval, 2000), max(1, deadline - elapsed)))
          poll(handle, opts, started)

        {:ok, _} ->
          finish_error(
            handle,
            :invalid_response,
            "Exa returned an unknown research status; inspect service docs and resume.",
            opts
          )

        {:error, %{reason: reason} = issue}
        when reason in [:rate_limited, :transport, :timeout] ->
          Process.sleep(min(retry_delay(issue, opts), max(1, deadline - elapsed)))
          poll(handle, opts, started)

        {:error, issue} ->
          finish_error(handle, issue.reason, issue.message, opts)
      end
    end
  end

  defp retry_delay(issue, opts) do
    default = Keyword.get(opts, :poll_interval, 2000)

    case Integer.parse(Map.get(issue, :retry_after) || "") do
      {seconds, ""} when seconds > 0 -> max(default, seconds * 1000)
      _ -> default
    end
  end

  defp bounded_usage(value) do
    if byte_size(Jason.encode!(value)) <= 1000,
      do: value,
      else: %{"notice" => "Usage metadata cut; inspect cached response."}
  end

  defp finish_error(handle, reason, message, opts) do
    record =
      Map.merge(handle, %{
        status: "error",
        local_complete: true,
        reason: to_string(reason),
        message: message
      })

    persist_and_notify(handle, record, opts)
  end

  defp persist_and_notify(handle, record, opts) do
    case save(record) do
      :ok ->
        notify(handle, stringify(record), opts)

      _ ->
        deliver(
          Keyword.get(opts, :notify),
          {:seedling_research, handle.id,
           %{
             status: "error",
             reason: "storage",
             message: "Research persistence failed; retry resume_research/2."
           }},
          opts
        )
    end
  end

  defp notify(handle, record, opts) do
    if not File.exists?(path(handle) <> ".ack") do
      event =
        {:seedling_research, handle.id,
         %{
           status: record["status"],
           result_id: record["result_id"],
           reason: record["reason"],
           message: record["message"],
           cost_dollars: record["cost_dollars"],
           usage: record["usage"],
           jobs_dir: handle.jobs_dir,
           cache_dir: record["cache_dir"] || Store.root(opts)
         }}

      recipient = Keyword.get(opts, :notify)
      deliver(recipient, event, opts)

      if match?({:agent, _}, recipient) do
        Process.sleep(Keyword.get(opts, :notify_interval, 5000))
        notify(handle, record, opts)
      end
    end
  end

  defp deliver({:agent, name}, event, opts) do
    resolver = Keyword.get(opts, :agent_resolver, &NanoAgent.whereis/1)

    try do
      case resolver.(name) do
        pid when is_pid(pid) -> if Process.alive?(pid), do: send(pid, event)
        _ -> :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp deliver(pid, event, _) when is_pid(pid), do: send(pid, event)
  defp deliver(_, _, _), do: :ok

  defp recipient(stored, opts) do
    Keyword.get(
      opts,
      :notify,
      if(stored["notify_agent"], do: {:agent, stored["notify_agent"]}, else: self())
    )
  end

  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp save(handle) do
    case Files.write(path(handle), Jason.encode!(handle)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp path(handle), do: Path.join(handle.jobs_dir, handle.id <> ".json")
  defp dir(opts), do: Keyword.get(opts, :jobs_dir, "/tmp/seedling-search-jobs")
  defp agent_name({:agent, name}), do: name
  defp agent_name(_), do: nil

  defp handle(%{id: id, jobs_dir: dir}, _opts) when is_binary(dir) do
    with :ok <- valid_id(id), do: {:ok, %{id: id, jobs_dir: dir}}
  end

  defp handle(%{"id" => id, "jobs_dir" => dir}, _opts) when is_binary(dir) do
    with :ok <- valid_id(id), do: {:ok, %{id: id, jobs_dir: dir}}
  end

  defp handle(id, opts) do
    with :ok <- valid_id(id), true <- is_binary(dir(opts)) do
      {:ok, %{id: id, jobs_dir: dir(opts)}}
    else
      false -> HTTP.error(:invalid_options, "jobs_dir must be a path string.")
      error -> error
    end
  end

  defp valid_id(id) do
    if is_binary(id) and byte_size(id) in 1..200 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id),
      do: :ok,
      else:
        HTTP.error(
          :invalid_job,
          "Pass the research handle or service id; ids contain letters, digits, _ and - only."
        )
  end

  defp validate_options(effort, notify, opts) do
    valid_notify =
      is_pid(notify) or notify == nil or match?({:agent, name} when is_binary(name), notify)

    if is_binary(dir(opts)) and dir(opts) != "" and
         effort in ["minimal", "low", "medium", "high", "xhigh", "auto", "ultra"] and valid_notify and
         Enum.all?([:poll_interval, :notify_interval, :research_timeout, :timeout], fn key ->
           value = Keyword.get(opts, key, 2000)
           is_integer(value) and value > 0
         end),
       do: :ok,
       else:
         HTTP.error(
           :invalid_options,
           "Use a documented effort, pid/{:agent, name}/nil notify, and positive poll/notify/deadline intervals."
         )
  end
end
