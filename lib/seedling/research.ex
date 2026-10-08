defmodule Seedling.Research do
  @moduledoc "Async Exa Agent research (current /agent/runs API). start(query) returns local ref immediately; owner receives {:research, ref, result}. Results cached, remote id retained. Default budget $1. Resume with watch(remote_id). Workers are not durable; remote jobs are."
  alias Seedling.Web.Cache

  def start(query, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    pid =
      spawn(fn ->
        body = %{
          query: query,
          effort: "auto",
          budget: %{maxCostDollars: Keyword.get(opts, :max_cost, 1)}
        }

        body = if opts[:schema], do: Map.put(body, :outputSchema, opts[:schema]), else: body

        result =
          with {:ok, %{"id" => id}} <- Seedling.Search.request("/agent/runs", body, opts) do
            send(owner, {:research_started, ref, id})
            poll(id, opts, deadline(opts))
          end

        send(owner, {:research, ref, result})
      end)

    {:ok, %{ref: ref, pid: pid}}
  end

  def watch(id, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()
    pid = spawn(fn -> send(owner, {:research, ref, poll(id, opts, deadline(opts))}) end)
    {:ok, %{ref: ref, pid: pid}}
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
