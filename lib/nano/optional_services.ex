defmodule Nano.OptionalServices do
  @moduledoc """
  A failure-isolating home for optional services. Supervise this manager in the main tree;
  it starts immediately, even if an optional module/configuration is missing or corrupt.
  Each service gets its own supervised retry slot, so one failed/slow start does not block
  the node or another service. Existing state is never removed or repaired automatically.

      {Nano.OptionalServices, specs: [{MCP, []}, {Bots, model: "..."}]}
      Nano.OptionalServices.status()
      Nano.OptionalServices.retry(MCP)

  `specs:` defaults to `[]`. Entries are ordinary Supervisor child specs; IDs must be
  unique (give explicit map specs for multiple instances). Malformed specs are recorded
  as failures and retried, not raised during manager boot. Duplicate IDs receive a
  positional ID in status so no configured entry silently disappears.

  `status/1` returns a map from service ID to `%{status: :starting | :running | :failed,
  attempts: n, pid: service_supervisor_or_nil, error: bounded_string_or_nil,
  next_retry_at: monotonic_milliseconds_or_nil}`. Running means its supervisor started,
  not application-level readiness. `next_retry_in_ms` is computed when queried.
  Retry backoff defaults to 1s..30s (`retry_ms:`, `max_retry_ms:`); repeated identical
  failures are logged once per slot, with bounded text and without logging spec arguments.

  Manager shutdown stops all slots and service trees. A crashed service is restarted by
  its own supervisor; if that tree exhausts its restart intensity, the slot retries it.
  A hung service initialization leaves only its own slot `:starting`; it does not block
  status or boot. This is isolation, not a replacement for a service's startup timeout.
  Use `name: nil` and the returned pid for isolated tests/embedded managers.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def retry(id, server \\ __MODULE__), do: GenServer.call(server, {:retry, id})

  @doc """
  Whether this manager owns the desired ID, or the default manager's application
  configuration declares it. Lazy facades must not start a competing process while true.
  `:nano, :optional_services` remains authoritative while the default manager is absent
  or restarting; explicitly addressed isolated managers do not use that global fallback.
  Declare production specs in application config, not only start_link arguments, to
  protect the restart gap. This function never invokes a service's child_spec callback.
  """
  def configured?(id, server \\ __MODULE__) do
    configured_in_application?(id, server) or configured_in_manager?(id, server)
  end

  defp configured_in_application?(id, __MODULE__) do
    Application.get_env(:nano, :optional_services, [])
    |> List.wrap()
    |> Enum.any?(&(spec_id(&1, :unknown) == id))
  end

  defp configured_in_application?(_, _), do: false

  defp configured_in_manager?(id, server) do
    GenServer.call(server, {:configured, id})
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    specs = Keyword.get(opts, :specs, [])
    specs = if is_list(specs), do: specs, else: [specs]
    retry_ms = positive(Keyword.get(opts, :retry_ms), 1000)
    max_ms = max(retry_ms, positive(Keyword.get(opts, :max_retry_ms), 30_000))

    services =
      specs
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {spec, index}, acc ->
        id = spec_id(spec, index)
        id = unique_id(id, index, acc)

        Map.put(acc, id, %{
          spec: spec,
          slot: nil,
          status: :starting,
          attempts: 0,
          pid: nil,
          error: nil,
          next_retry_at: nil
        })
      end)

    send(self(), :start_slots)
    {:ok, %{supervisor: supervisor, services: services, retry_ms: retry_ms, max_ms: max_ms}}
  end

  defp positive(n, _) when is_integer(n) and n > 0 and n <= 4_294_967_295, do: n
  defp positive(_, default), do: default

  defp unique_id(id, index, acc) do
    if Map.has_key?(acc, id), do: unique_id({:duplicate, index, id}, index, acc), else: id
  end

  defp spec_id(%{id: id}, _), do: id
  defp spec_id({module, _}, _) when is_atom(module), do: module
  defp spec_id(module, _) when is_atom(module), do: module
  defp spec_id(_, index), do: {:invalid_spec, index}

  @impl true
  def handle_call(:status, _, s) do
    now = System.monotonic_time(:millisecond)

    result =
      Map.new(s.services, fn {id, entry} ->
        public = Map.drop(entry, [:spec, :slot])

        {id,
         Map.put(
           public,
           :next_retry_in_ms,
           if(entry.next_retry_at, do: max(0, entry.next_retry_at - now), else: nil)
         )}
      end)

    {:reply, result, s}
  end

  def handle_call({:configured, id}, _, s), do: {:reply, Map.has_key?(s.services, id), s}

  def handle_call({:retry, id}, _, s) do
    case s.services[id] do
      %{slot: pid} when is_pid(pid) ->
        send(pid, :retry_now)
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, :unknown_service}, s}
    end
  end

  @impl true
  def handle_info(:start_slots, s) do
    services =
      Map.new(s.services, fn {id, entry} ->
        {:ok, slot} =
          DynamicSupervisor.start_child(
            s.supervisor,
            {Nano.OptionalServices.Slot,
             manager: self(),
             id: id,
             spec: entry.spec,
             retry_ms: s.retry_ms,
             max_retry_ms: s.max_ms}
          )

        {id, %{entry | slot: slot}}
      end)

    {:noreply, %{s | services: services}}
  end

  def handle_info({:optional_service, id, slot, report}, s) do
    case s.services[id] do
      nil -> {:noreply, s}
      entry -> {:noreply, put_in(s.services[id], Map.merge(entry, Map.put(report, :slot, slot)))}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{supervisor: pid} = s),
    do: {:stop, {:optional_supervisor_exited, reason}, s}

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if Process.alive?(s.supervisor), do: Supervisor.stop(s.supervisor, :shutdown, :infinity)
  end
end

defmodule Nano.OptionalServices.Slot do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    s = %{
      manager: opts[:manager],
      id: opts[:id],
      spec: opts[:spec],
      retry_ms: opts[:retry_ms],
      max_retry_ms: opts[:max_retry_ms],
      failures: 0,
      attempts: 0,
      supervisor: nil,
      timer: nil,
      last_error: nil,
      attempt_ref: make_ref()
    }

    send(self(), {:attempt, s.attempt_ref})
    {:ok, s}
  end

  @impl true
  def handle_info({:attempt, ref}, %{supervisor: nil, attempt_ref: ref} = s) do
    s = %{s | attempts: s.attempts + 1, timer: nil, attempt_ref: nil}
    report(s, :starting, s.last_error, nil)

    result =
      try do
        spec = Supervisor.child_spec(s.spec, [])
        Supervisor.start_link([spec], strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
      rescue
        e -> {:error, {e.__struct__, Exception.message(e)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, supervisor} ->
        s = %{s | supervisor: supervisor, failures: 0, last_error: nil}
        report(s, :running, nil, nil)
        {:noreply, s}

      {:error, reason} ->
        {:noreply, failed(s, reason)}
    end
  end

  def handle_info(:retry_now, %{supervisor: nil} = s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    ref = make_ref()
    send(self(), {:attempt, ref})
    {:noreply, %{s | timer: nil, attempt_ref: ref}}
  end

  def handle_info(:retry_now, s), do: {:noreply, s}

  def handle_info({:EXIT, pid, reason}, %{supervisor: pid} = s),
    do: {:noreply, failed(%{s | supervisor: nil}, reason)}

  def handle_info(_, s), do: {:noreply, s}

  defp failed(s, reason) do
    error =
      inspect(failure_reason(reason), limit: 8, printable_limit: 400, width: 120)
      |> String.slice(0, 600)

    if s.last_error != error,
      do:
        Logger.warning(
          "Optional service #{inspect(s.id, limit: 3, printable_limit: 80)} unavailable: #{error}"
        )

    delay = min(s.max_retry_ms, s.retry_ms * Integer.pow(2, min(s.failures, 16)))
    next = System.monotonic_time(:millisecond) + delay
    ref = make_ref()
    timer = Process.send_after(self(), {:attempt, ref}, delay)
    s = %{s | failures: s.failures + 1, last_error: error, timer: timer, attempt_ref: ref}
    report(s, :failed, error, next)
    s
  end

  defp failure_reason({:shutdown, {:failed_to_start_child, _id, reason}}),
    do: failure_reason(reason)

  defp failure_reason({:EXIT, {%{__exception__: true} = error, _stack}}),
    do: {error.__struct__, Exception.message(error)}

  defp failure_reason({:EXIT, reason}), do: failure_reason(reason)
  defp failure_reason(reason), do: reason

  defp report(s, status, error, next) do
    send(
      s.manager,
      {:optional_service, s.id, self(),
       %{
         status: status,
         attempts: s.attempts,
         pid: s.supervisor,
         error: error,
         next_retry_at: next
       }}
    )
  end

  @impl true
  def terminate(_, s) do
    if s.timer, do: Process.cancel_timer(s.timer)

    if is_pid(s.supervisor) and Process.alive?(s.supervisor),
      do: Supervisor.stop(s.supervisor, :shutdown, :infinity)
  end
end
