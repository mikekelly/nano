defmodule Seedling.Background do
  @moduledoc "Restart-safe shell jobs: start(cmd, owner: name, cwd: path, timeout: ms, env: [{key,value}]). Returns {:ok,pid,id}; cancel(pid), info(pid), tail(path). Completion %{background: id,status: code,reason: atom,output: path,bytes: n} arrives by agent name. Survives agent, not node restart; durable outputs /data/background."
  use GenServer

  def start(command, opts) do
    owner = Keyword.get(opts, :owner)

    if is_binary(owner) and owner =~ ~r/^[\w.-]+$/ do
      id = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

      case GenServer.start(__MODULE__, {command, opts, owner, id, self()}) do
        {:ok, pid} -> {:ok, pid, id}
        error -> error
      end
    else
      {:error, :invalid_owner}
    end
  end

  def cancel(pid), do: GenServer.cast(pid, :cancel)
  def info(pid), do: GenServer.call(pid, :info)

  def tail(path, opts \\ []) do
    with {:ok, text} <- File.read(path) do
      cap = Keyword.get(opts, :bytes, 12000)

      {:ok,
       text
       |> String.split("\n")
       |> Enum.take(-Keyword.get(opts, :lines, 100))
       |> Enum.join("\n")
       |> String.slice(-cap, cap)}
    end
  end

  @impl true
  def init({command, opts, owner, id, caller}) do
    Process.put(:"$callers", [NanoAgent.whereis(owner) || caller])
    dir = Path.join([Keyword.get(opts, :root, "/data/background"), owner, id])
    File.mkdir_p!(dir)
    output = Path.join(dir, "output.log")

    script =
      "exec setsid --wait sh -c " <>
        Seedling.Tools.quote_arg(
          "echo $$ > " <>
            Seedling.Tools.quote_arg(Path.join(dir, "session.pid")) <> "; " <> command
        ) <> " > " <> Seedling.Tools.quote_arg(output) <> " 2>&1"

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", script],
        cd: Keyword.get(opts, :cwd, "/app"),
        env:
          Enum.map(Keyword.get(opts, :env, []), fn {k, v} ->
            {String.to_charlist(k), String.to_charlist(v)}
          end)
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    timer = Process.send_after(self(), :timeout, Keyword.get(opts, :timeout, 3_600_000))

    state = %{
      id: id,
      owner: owner,
      output: output,
      port: port,
      os_pid: os_pid,
      timer: timer,
      reason: :exit,
      status: :running
    }

    File.write!(Path.join(dir, "metadata.json"), Jason.encode!(Map.drop(state, [:port, :timer])))
    {:ok, state}
  end

  @impl true
  def handle_call(:info, _from, s), do: {:reply, Map.drop(s, [:port, :timer]), s}
  @impl true
  def handle_cast(:cancel, s), do: {:noreply, kill(s, :cancelled)}
  @impl true
  def handle_info(:timeout, s), do: {:noreply, kill(s, :timeout)}
  def handle_info({port, {:data, _}}, %{port: port} = s), do: {:noreply, s}

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    Process.cancel_timer(s.timer)
    s = %{s | status: status}

    File.write!(
      Path.join(Path.dirname(s.output), "result.json"),
      Jason.encode!(Map.drop(s, [:port, :timer]))
    )

    send(self(), :deliver)
    {:noreply, s}
  end

  def handle_info(:deliver, s) do
    case NanoAgent.whereis(s.owner) do
      nil ->
        Process.send_after(self(), :deliver, 1000)
        {:noreply, s}

      pid ->
        bytes =
          case File.stat(s.output) do
            {:ok, stat} -> stat.size
            _ -> 0
          end

        send(pid, %{
          background: s.id,
          status: s.status,
          reason: s.reason,
          output: s.output,
          bytes: bytes
        })

        {:stop, :normal, s}
    end
  end

  defp kill(%{status: :running} = s, reason) do
    session =
      case File.read(Path.join(Path.dirname(s.output), "session.pid")) do
        {:ok, text} ->
          String.trim(text)

        _ ->
          Process.sleep(10)

          case File.read(Path.join(Path.dirname(s.output), "session.pid")) do
            {:ok, text} -> String.trim(text)
            _ -> to_string(s.os_pid)
          end
      end

    System.cmd("kill", ["-KILL", "--", "-#{session}"], stderr_to_stdout: true)
    %{s | reason: reason}
  end

  defp kill(s, _), do: s
end
