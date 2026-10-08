defmodule Seedling.Background.Guardian do
  @moduledoc false
  # A separate, unlinked guardian can observe even :kill (terminate callbacks cannot).
  def watch(worker, record) do
    spawn(fn ->
      if pid = resolve(record.owner), do: Process.put(:"$callers", [pid])
      ref = Process.monitor(worker)

      receive do
        {:DOWN, ^ref, :process, ^worker, :normal} ->
          :ok

        {:DOWN, ^ref, :process, ^worker, reason} ->
          kill_group(record.group_path, 50)
          record = latest(record)

          if record.status == :running do
            interrupted(record, {:worker_exit, inspect(reason)})
          else
            deliver(record)
          end
      end
    end)
  end

  def interrupted(record, reason) do
    bytes =
      case File.stat(record.output_path) do
        {:ok, stat} -> stat.size
        _ -> 0
      end

    record =
      Map.merge(record, %{
        status: :interrupted,
        interruption: reason,
        bytes: bytes,
        finished_at: System.system_time(:millisecond)
      })

    :ok = Seedling.Background.persist(record)
    deliver(record)
  end

  def deliver(record) do
    case resolve(record.owner) do
      nil when is_binary(record.owner) ->
        Process.sleep(250)
        deliver(record)

      nil ->
        :ok

      pid ->
        send(pid, {:seedling_background, record})
        :ok
    end
  end

  defp latest(record) do
    case Seedling.Background.receipt(record.receipt_path) do
      {:ok, saved} -> saved
      _ -> record
    end
  end

  defp kill_group(path, retries) do
    case File.read(path) do
      {:ok, group} ->
        case Integer.parse(String.trim(group)) do
          {pid, ""} when pid > 1 ->
            System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)

          _ ->
            :ok
        end

      _ when retries > 0 ->
        Process.sleep(10)
        kill_group(path, retries - 1)

      _ ->
        :ok
    end
  end

  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)

  defp resolve(name) when is_binary(name) do
    NanoAgent.whereis(name)
  rescue
    _ -> nil
  end

  defp resolve(_), do: nil
end

defmodule Seedling.Background.Recovery do
  @moduledoc """
  Optional boot child: `{Seedling.Background.Recovery, dir: "/data/seedling/background"}`.
  Start after Nano.Names. Running disk records left by a node crash are marked interrupted
  and a named-owner completion is retried until that agent registers. Commands are not
  rerun (which would repeat side effects). OS survival across node restart is not promised.
  Never start this scanner against a directory actively used by another running node.
  """
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, "/data/seedling/background")

    for path <- Path.wildcard(Path.join(dir, "*.term")) do
      case Seedling.Background.receipt(path) do
        {:ok, %{status: :running} = record} ->
          # Do not interrupt live workers if this child is merely restarted in this VM.
          if not live_worker?(record) do
            spawn(fn -> Seedling.Background.Guardian.interrupted(record, :node_restart) end)
          end

        _ ->
          :ok
      end
    end

    {:ok, %{dir: dir}}
  end

  defp live_worker?(record) do
    node(record.pid) == node() and
      case Process.info(record.pid, :dictionary) do
        {:dictionary, dict} -> dict[:seedling_background_id] == record.id
        _ -> false
      end
  end
end
