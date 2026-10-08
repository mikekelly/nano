defmodule Seedling.Research do
  @moduledoc "Async Exa Agent research (current /agent/runs API). start(query) returns local ref immediately; owner receives {:research, ref, result}. Results cached, remote id retained. Default budget $1. Resume with watch(remote_id). Named owner strings enable durable pending records and restart-resolved delivery; add the optional Seedling.Research.Pending supervisor child to resume on reboot. PID owners are ephemeral."
  alias Seedling.Web.Cache

  def start(query, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    ref =
      if is_binary(owner),
        do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        else: make_ref()

    pid =
      spawn(fn ->
        Process.put(:research_token, ref)

        body = %{
          query: query,
          effort: "auto",
          budget: %{maxCostDollars: Keyword.get(opts, :max_cost, 1)}
        }

        body = if opts[:schema], do: Map.put(body, :outputSchema, opts[:schema]), else: body

        result =
          with {:ok, %{"id" => id}} <- Seedling.Search.request("/agent/runs", body, opts) do
            notify(owner, {:research_started, ref, id}, opts)

            if is_binary(owner) do
              record = Seedling.Research.Pending.record(id, owner, ref, opts)

              with :ok <- Seedling.Research.Pending.save(record, opts) do
                result = await(id, opts)

                case result do
                  {:ok, summary} ->
                    Seedling.Research.Pending.complete(record, summary, opts)
                    :durable_delivery

                  _ ->
                    result
                end
              end
            else
              await(id, opts)
            end
          end

        if result != :durable_delivery, do: notify(owner, {:research, ref, result}, opts)
      end)

    {:ok, %{ref: ref, pid: pid}}
  end

  def watch(id, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    ref =
      if is_binary(owner),
        do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        else: make_ref()

    pid =
      spawn(fn ->
        Process.put(:research_token, ref)

        if is_binary(owner) do
          record = Seedling.Research.Pending.record(id, owner, ref, opts)

          with :ok <- Seedling.Research.Pending.save(record, opts),
               do: Seedling.Research.Pending.resume(record, opts)
        else
          notify(owner, {:research, ref, await(id, opts)}, opts)
        end
      end)

    {:ok, %{ref: ref, pid: pid}}
  end

  @doc false
  def await(id, opts), do: poll(id, opts, deadline(opts))

  defp notify(owner, message, opts) do
    target =
      if is_binary(owner),
        do: Keyword.get(opts, :resolver, &NanoAgent.whereis/1).(owner),
        else: owner

    if is_pid(target), do: send(target, message), else: :owner_unavailable
  rescue
    _ -> :owner_unavailable
  end

  def status(id, opts \\ []) do
    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,200}\z/, id),
      do: Seedling.Search.request("/agent/runs/" <> id, nil, opts),
      else: {:error, :invalid_run_id}
  end

  def cancel(id, opts \\ []) do
    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,200}\z/, id),
      do: Seedling.Search.request("/agent/runs/" <> id <> "/cancel", %{}, opts),
      else: {:error, :invalid_run_id}
  end

  defp deadline(opts),
    do: System.monotonic_time(:millisecond) + Keyword.get(opts, :job_timeout, 900_000)

  defp poll(id, opts, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:research_timeout, id}}
    else
      case status(id, opts) do
        {:ok, %{"status" => state} = data}
        when state in ["completed", "failed", "canceled", "cancelled"] ->
          with {:ok, cache_id} <-
                 Cache.put(Jason.encode!(data), %{provider: "exa", run_id: id}, opts) do
            {:ok, %{run_id: id, status: state, id: cache_id, read: "Seedling.Web.read/2"}}
          end

        {:ok, _} ->
          Process.sleep(Keyword.get(opts, :poll_interval, 5000))
          poll(id, opts, deadline)

        {:error, {:http, code}} when code in [429, 500, 502, 503, 504] ->
          Process.sleep(Keyword.get(opts, :poll_interval, 5000))
          poll(id, opts, deadline)

        error ->
          error
      end
    end
  end
end
