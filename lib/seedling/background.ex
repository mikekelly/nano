defmodule Seedling.Background do
  @moduledoc """
  Unlinked OS-command workers, independent of eval/agent lifetime.

      {:ok, task} = Seedling.Background.start("mix test", owner: "my-agent", cwd: "/app")
      Seedling.Background.status(task)
      Seedling.Background.cancel(task)

  Completion is `{:seedling_background, receipt}` (metadata only). Named owners are
  resolved again on completion and retried while absent. Receipt and full merged output
  are stored on disk. This survives agent/eval restarts. See Seedling.Background.Recovery for boot
  interruption records; OS execution is not resumed after BEAM/host restarts.
  `owner:` may also be a pid (not restart safe); defaults to the calling named agent.
  `dir:` defaults to /data/seedling/background; `timeout:` defaults to :infinity.
  Requires POSIX bash, setsid and kill. Commands are trusted shell code.
  """
  use GenServer

  def start(command, opts \\ []) when is_binary(command) do
    owner = Keyword.get(opts, :owner, infer_owner())
    callers = Process.get(:"$callers", [])
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.expand(Keyword.get(opts, :dir, "/data/seedling/background"))

    with :ok <- File.mkdir_p(dir),
         {:ok, pid} <- GenServer.start(__MODULE__, {command, opts, owner, callers, id, dir}) do
      {:ok, GenServer.call(pid, :status)}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  def status(%{pid: pid, receipt_path: path}) do
    case status(pid) do
      {:error, :worker_not_running} -> receipt(path)
      result -> result
    end
  end

  def status(pid) when is_pid(pid) do
    GenServer.call(pid, :status)
  catch
    :exit, _ -> {:error, :worker_not_running}
  end

  def cancel(%{pid: pid}), do: cancel(pid)

  def cancel(pid) do
    GenServer.call(pid, :cancel)
  catch
    :exit, _ -> {:error, :worker_not_running}
  end

  def receipt(path) do
    with {:ok, bytes} <- File.read(path) do
      {:ok, :erlang.binary_to_term(bytes, [:safe])}
    end
  rescue
    _ -> {:error, :invalid_receipt}
  end

  defp infer_owner do
    pids = [self() | Process.get(:"$callers", [])]

    Enum.find_value(Nano.Names.all(), fn
      {{:agent, name}, pid} -> if pid in pids, do: name
      _ -> nil
    end) || self()
  rescue
    _ -> self()
  end

  @impl true
  def init({command, opts, owner, callers, id, dir}) do
    Process.put(:"$callers", if(pid = resolve(owner), do: [pid], else: callers))
    Process.put(:seedling_background_id, id)
    output = Path.join(dir, id <> ".log")
    receipt = Path.join(dir, id <> ".term")
    timeout = Keyword.get(opts, :timeout, :infinity)

    env =
      Enum.map(Keyword.get(opts, :env, []), fn {k, v} ->
        {String.to_charlist(to_string(k)),
         if(v == nil, do: false, else: String.to_charlist(to_string(v)))}
      end)

    # setsid gives the command and its descendants a separate process group.
    port =
      Port.open(
        {:spawn_executable, System.find_executable("setsid")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:args,
           [
             "--wait",
             System.find_executable("bash"),
             "-c",
             "echo $$ > \"$1\"; exec bash -c \"$2\"",
             "seedling",
             Path.join(dir, id <> ".pgid"),
             command
           ]},
          {:cd, Path.expand(Keyword.get(opts, :cwd, File.cwd!()))},
          {:env, env}
        ]
      )

    {:ok, file} = File.open(output, [:write, :binary])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    if timeout != :infinity, do: Process.send_after(self(), :timeout, timeout)
    Process.send_after(self(), :attribute, 0)

    s = %{
      id: id,
      pid: self(),
      owner: owner,
      command: command,
      output_path: output,
      receipt_path: receipt,
      status: :running,
      exit_code: nil,
      bytes: 0,
      started_at: System.system_time(:millisecond),
      os_pid: os_pid,
      group_path: Path.join(dir, id <> ".pgid")
    }

    :ok = persist(s)
    Seedling.Background.Guardian.watch(self(), s)
    {:ok, %{public: s, port: port, file: file, reason: nil}}
  end

  @impl true
  def handle_call(:status, _, s), do: {:reply, s.public, s}

  def handle_call(:cancel, _, %{public: %{status: :running}} = s),
    do: {:reply, :ok, stop_command(s, :cancelled)}

  def handle_call(:cancel, _, s), do: {:reply, {:error, :already_finished}, s}

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = s) do
    :ok = IO.binwrite(s.file, bytes)
    {:noreply, put_in(s.public.bytes, s.public.bytes + byte_size(bytes))}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s) do
    File.close(s.file)

    public =
      Map.merge(s.public, %{
        status: s.reason || :completed,
        exit_code: code,
        finished_at: System.system_time(:millisecond)
      })

    :ok = persist(public)
    send(self(), :deliver)
    {:noreply, %{s | public: public, file: nil}}
  end

  def handle_info(:timeout, %{public: %{status: :running}} = s),
    do: {:noreply, stop_command(s, s.reason || :timed_out)}

  def handle_info(:attribute, s) do
    if pid = resolve(s.public.owner), do: Process.put(:"$callers", [pid])
    if s.public.status == :running, do: Process.send_after(self(), :attribute, 1000)
    {:noreply, s}
  end

  def handle_info(:deliver, s) do
    case resolve(s.public.owner) do
      nil ->
        if is_pid(s.public.owner) do
          {:stop, :normal, s}
        else
          Process.send_after(self(), :deliver, 250)
          {:noreply, s}
        end

      pid ->
        send(pid, {:seedling_background, s.public})
        {:stop, :normal, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)

  defp resolve(name) when is_binary(name) do
    case NanoAgent.whereis(name) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve(_), do: nil

  @doc false
  def persist(public) do
    with :ok <- File.write(public.receipt_path <> ".tmp", :erlang.term_to_binary(public)),
         :ok <- File.rename(public.receipt_path <> ".tmp", public.receipt_path),
         do: :ok
  end

  defp stop_command(s, reason) do
    case File.read(s.public.group_path) do
      {:ok, group} ->
        System.cmd("kill", ["-KILL", "--", "-" <> String.trim(group)], stderr_to_stdout: true)

      _ ->
        Process.send_after(self(), :timeout, 10)
    end

    %{s | reason: reason}
  end
end
