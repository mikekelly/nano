defmodule Seedling.Research.Pending do
  @moduledoc "Optional supervisor child: resumes durable named-owner research and retries delivery. Add {Seedling.Research.Pending, []}. Disk records contain no keys; credentials re-read on reboot. At-least-once delivery (no receiver ack)."
  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def init(opts) do
    Process.send_after(self(), :scan, 0)
    {:ok, %{opts: opts, active: %{}}}
  end

  def handle_info(:scan, state) do
    active = Map.reject(state.active, fn {_id, pid} -> not Process.alive?(pid) end)

    active =
      Enum.reduce(list(state.opts), active, fn record, acc ->
        if Map.has_key?(acc, record["token"]) or worker_alive?(record) do
          acc
        else
          opts = restore(record, state.opts)
          pid = spawn(fn -> resume(record, opts) end)
          Map.put(acc, record["token"], pid)
        end
      end)

    Process.send_after(self(), :scan, Keyword.get(state.opts, :scan_interval, 5000))
    {:noreply, %{state | active: active}}
  end

  defp worker_alive?(record) do
    pid = :erlang.list_to_pid(String.to_charlist(record["worker_pid"] || ""))

    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> dict[:research_token] == record["token"]
      _ -> false
    end
  rescue
    _ -> false
  end

  def dir(opts), do: Keyword.get(opts, :pending_dir, "/data/seedling-research-pending")

  def save(record, opts) do
    File.mkdir_p!(dir(opts))
    File.chmod!(dir(opts), 0o700)
    path = path(record["token"], opts)
    tmp = path <> "." <> Integer.to_string(System.unique_integer([:positive]))
    with :ok <- File.write(tmp, Jason.encode!(record)), :ok <- File.rename(tmp, path), do: :ok
  rescue
    _ -> {:error, :pending_write_failed}
  end

  defp path(token, opts), do: Path.join(dir(opts), token <> ".json")

  def list(opts \\ []) do
    Path.wildcard(Path.join(dir(opts), "*.json"))
    |> Enum.flat_map(fn p ->
      with {:ok, raw} <- File.read(p), {:ok, r} <- Jason.decode(raw), true <- valid?(r) do
        [r]
      else
        _ -> []
      end
    end)
  end

  defp valid?(r),
    do:
      is_binary(r["owner"]) and is_binary(r["run_id"]) and is_binary(r["token"]) and
        Regex.match?(~r/\A[0-9a-f]{32}\z/, r["token"])

  def record(id, owner, token, opts) do
    stored =
      opts
      |> Keyword.take([:cache_dir, :base_url, :poll_interval, :job_timeout])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    %{
      "run_id" => id,
      "owner" => owner,
      "token" => token,
      "options" => stored,
      "worker_pid" => to_string(:erlang.pid_to_list(self()))
    }
  end

  defp restore(record, opts) do
    allowed = %{
      "cache_dir" => :cache_dir,
      "base_url" => :base_url,
      "poll_interval" => :poll_interval,
      "job_timeout" => :job_timeout
    }

    restored =
      Enum.flat_map(record["options"] || %{}, fn {k, v} ->
        if allowed[k], do: [{allowed[k], v}], else: []
      end)

    Keyword.merge(restored, opts)
  end

  def resume(record, opts) do
    Process.put(:research_token, record["token"])
    record = Map.put(record, "worker_pid", to_string(:erlang.pid_to_list(self())))
    save(record, opts)

    case record["result"] do
      nil ->
        result = Seedling.Research.await(record["run_id"], opts)

        case result do
          {:ok, summary} -> complete(record, summary, opts)
          _ -> :pending
        end

      summary ->
        deliver(record, summary, opts)
    end
  end

  def complete(record, summary, opts) do
    summary = Map.new(summary, fn {k, v} -> {to_string(k), v} end)

    cached =
      case Seedling.Web.Cache.get(summary["id"], opts) do
        {:ok, entry} -> entry
        _ -> nil
      end

    record = record |> Map.put("result", summary) |> Map.put("cached", cached)
    with :ok <- save(record, opts), do: deliver(record, summary, opts)
  end

  def deliver(record, summary, opts) do
    resolver = Keyword.get(opts, :resolver, &NanoAgent.whereis/1)

    case resolver.(record["owner"]) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          cache_id =
            case record["cached"] do
              %{"text" => text, "meta" => meta} ->
                case Seedling.Web.Cache.put(text, meta, opts) do
                  {:ok, id} -> id
                  _ -> summary["id"]
                end

              _ ->
                summary["id"]
            end

          result = %{
            run_id: summary["run_id"],
            status: summary["status"],
            id: cache_id,
            read: "Seedling.Web.read/2"
          }

          send(pid, {:research, record["token"], {:ok, result}})
          File.rm(path(record["token"], opts))
          :ok
        else
          :pending
        end

      _ ->
        :pending
    end
  rescue
    _ -> :pending
  end
end
