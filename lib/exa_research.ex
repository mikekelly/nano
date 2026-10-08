defmodule Exa.Research do
  @moduledoc """
  Detached Exa Agent research via `/agent/runs` (not the legacy research API).

      {:ok, %{id: id}} = Exa.Research.start("What is OTP?", effort: "low")
      # Later: {:exa_research, id, {:ok, %{data: run, truncated: false}}}
      Exa.Research.get(id)
      Exa.Research.cancel(id)
      Exa.Research.resume(id)

  `start/2` creates a billed remote run, then returns its ID and an unlinked poller
  PID. `resume/2` only attaches a new poller; it never creates another billed run.
  Save the ID in your own goals/state. Pollers survive caller-process restarts,
  **not node restarts**. After node restart, call `resume/2` with the saved ID.
  Concurrent resumes produce independent pollers and potentially duplicate events.

  Completion is sent to the caller's agent **name**, discovered through
  `Delegation.caller_name/0`. Set `notify: "agent-name"` to override or `notify: pid`
  for ordinary processes/tests (PIDs do not survive restart). Name lookup is repeated
  on delivery; missing names are retried for `delivery_timeout_ms` (default 60_000)
  every `delivery_interval_ms` (default 250). Delivery is best effort, not an
  acknowledged durable queue: a process dying just after send can lose the event.

  Polling defaults to `poll_interval_ms: 4_000`, `poll_timeout_ms: 900_000`.
  The deadline includes in-flight polling requests. Expiry emits an error but does
  **not** cancel remote work or stop billing; cancel explicitly when wanted.
  Transport errors stop polling (use `resume/2` to retry). Completed events contain
  the run including `output.text`, `output.structured`, `output.grounding`, and cost
  information, bounded by `Exa.bound/2`. Failed/cancelled runs emit `{:error, bound}`.
  `get/2` and `cancel/2` return bounded API snapshots even for failed/cancelled runs.

  Creation options: `effort` (default `"low"`), `output_schema`, `system_prompt`,
  `input`, `previous_run_id`, `data_sources`, and `budget`. Fixed efforts do not
  accept budget; see https://exa.ai/docs/reference/agent-api/create-a-run .
  Exa request options (including `transport`, `api_key`, `max_bytes`) pass through.
  Credentials are held only in request/poller memory, never persisted or logged.
  `resolve_name: fn name -> pid | nil end` overrides name lookup for isolated tests.
  """

  @body_options [
    output_schema: "outputSchema",
    system_prompt: "systemPrompt",
    input: "input",
    previous_run_id: "previousRunId",
    data_sources: "dataSources",
    budget: "budget"
  ]
  @defaults [
    poll_interval_ms: 4_000,
    poll_timeout_ms: 900_000,
    delivery_timeout_ms: 60_000,
    delivery_interval_ms: 250
  ]

  @doc "Create a remote run and detach polling. Returns `{:ok, %{id: id, poller: pid}}`."
  def start(query, opts \\ []) do
    with :ok <- validate_options(opts),
         true <- is_binary(query) and String.trim(query) != "",
         {:ok, target} <- target(opts),
         {:ok, run} <- request(:post, "/agent/runs", body(query, opts), opts),
         id when is_binary(id) <- Map.get(run, "id"),
         true <- valid_id?(id) do
      launch(id, target, opts)
    else
      {:error, value} -> error(value, opts)
      _ -> error(%{code: :invalid_query_or_response}, opts)
    end
  end

  @doc "Resume polling an existing ID without creating a run or retaining disk state."
  def resume(id, opts \\ []) do
    with :ok <- validate_options(opts),
         true <- valid_id?(id),
         {:ok, target} <- target(opts) do
      launch(id, target, opts)
    else
      {:error, value} -> error(value, opts)
      _ -> error(%{code: :invalid_id}, opts)
    end
  end

  @doc "Fetch one bounded run snapshot without starting a poller."
  def get(id, opts \\ []), do: snapshot(:get, id, "", opts)

  @doc "Cancel remote work. Accrued usage remains billed; terminal runs are unchanged."
  def cancel(id, opts \\ []), do: snapshot(:post, id, "/cancel", opts)

  defp snapshot(method, id, suffix, opts) do
    with :ok <- validate_options(opts),
         true <- valid_id?(id) do
      case request(method, path(id) <> suffix, nil, opts) do
        {:ok, run} -> {:ok, Exa.bound(run, opts)}
        {:error, value} -> error(value, opts)
      end
    else
      {:error, value} -> error(value, opts)
      _ -> error(%{code: :invalid_id}, opts)
    end
  end

  defp body(query, opts) do
    Enum.reduce(
      @body_options,
      %{"query" => query, "effort" => Keyword.get(opts, :effort, "low")},
      fn {key, field}, acc ->
        if Keyword.has_key?(opts, key), do: Map.put(acc, field, opts[key]), else: acc
      end
    )
  end

  defp validate_options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Enum.all?(@defaults, fn {key, default} ->
           value = Keyword.get(opts, key, default)
           is_integer(value) and value > 0
         end) and
         (not Keyword.has_key?(opts, :resolve_name) or is_function(opts[:resolve_name], 1)) do
      :ok
    else
      {:error, %{code: :invalid_options}}
    end
  end

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and String.match?(id, ~r/^[A-Za-z0-9_-]+$/)

  defp path(id), do: "/agent/runs/" <> id
  defp now, do: System.monotonic_time(:millisecond)
  defp setting(opts, key), do: Keyword.get(opts, key, Keyword.fetch!(@defaults, key))

  defp target(opts) do
    case Keyword.fetch(opts, :notify) do
      {:ok, pid} when is_pid(pid) ->
        {:ok, pid}

      {:ok, name} when is_binary(name) and byte_size(name) in 1..256 ->
        {:ok, name}

      :error ->
        case Delegation.caller_name() do
          {:ok, name} ->
            {:ok, name}

          _ ->
            {:error,
             %{
               code: :notify_required,
               message: "Use notify: pid or agent name outside an agent eval"
             }}
        end

      _ ->
        {:error, %{code: :invalid_notify}}
    end
  end

  defp launch(id, target, opts) do
    deadline = now() + setting(opts, :poll_timeout_ms)

    pid =
      spawn(fn ->
        result = poll(id, opts, deadline)

        deliver(
          target,
          {:exa_research, id, result},
          opts,
          now() + setting(opts, :delivery_timeout_ms)
        )
      end)

    {:ok, %{id: id, poller: pid}}
  end

  defp poll(id, opts, deadline) do
    case timed_request(id, opts, deadline) do
      {:ok, %{"status" => "completed"} = run} ->
        {:ok, Exa.bound(run, opts)}

      {:ok, %{"status" => status} = run} when status in ["failed", "cancelled"] ->
        error(run, opts)

      {:ok, %{"status" => status}} when status in ["queued", "running"] ->
        remaining = deadline - now()

        if remaining > 0 do
          Process.sleep(min(setting(opts, :poll_interval_ms), remaining))
          poll(id, opts, deadline)
        else
          error(%{code: :poll_timeout, id: id}, opts)
        end

      {:ok, _} ->
        error(%{code: :unexpected_status, id: id}, opts)

      {:error, value} ->
        error(value, opts)
    end
  end

  # Monitoring bounds even an injected transport that never returns. The request
  # subprocess is killed on deadline; no request result is left in the caller mailbox.
  defp timed_request(id, opts, deadline) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, %{code: :poll_timeout, id: id}}
    else
      parent = self()
      ref = make_ref()

      {pid, monitor} =
        spawn_monitor(fn -> send(parent, {ref, request(:get, path(id), nil, opts)}) end)

      receive do
        {^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          {:error, %{code: :poll_request_failed, id: id}}
      after
        remaining ->
          Process.exit(pid, :kill)
          Process.demonitor(monitor, [:flush])
          {:error, %{code: :poll_timeout, id: id}}
      end
    end
  end

  defp request(method, path, body, opts) do
    case Exa.request(method, path, body, opts) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:error, value} when is_map(value) -> {:error, value}
      _ -> {:error, %{code: :invalid_response}}
    end
  rescue
    _ -> {:error, %{code: :request_exception}}
  catch
    _, _ -> {:error, %{code: :request_exception}}
  end

  defp deliver(target, event, opts, deadline) do
    pid = resolve(target, opts)

    cond do
      is_pid(pid) and Process.alive?(pid) ->
        send(pid, event)

      now() >= deadline ->
        :delivery_expired

      true ->
        Process.sleep(min(setting(opts, :delivery_interval_ms), max(1, deadline - now())))
        deliver(target, event, opts, deadline)
    end
  end

  defp resolve(pid, _) when is_pid(pid), do: pid

  defp resolve(name, opts) do
    resolver = Keyword.get(opts, :resolve_name, &NanoAgent.whereis/1)
    resolver.(name)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp error(value, opts) do
    safe_opts = if is_list(opts) and Keyword.keyword?(opts), do: opts, else: []
    {:error, Exa.bound(value, safe_opts)}
  end
end
