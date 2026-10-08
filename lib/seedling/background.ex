defmodule Seedling.Background do
  @moduledoc """
  Unlinked shell jobs surviving eval/caller and agent restarts (not node restarts).

      {:ok, job, id} = Seedling.Background.start("make", owner: "alice", cwd: "/app")
      Seedling.Background.info(job)
      Seedling.Background.cancel(job)
      Seedling.Background.tail("/data/background/alice/<id>/output.log")

  Completion is `%{background: id, status: code, reason: atom, output: path, bytes: n}`,
  sent to the current agent registered under `owner`, retrying while absent. Output is
  never included in the event. `result(owner, id, root: path)` recovers a completed
  string-keyed result map from disk after the worker exits. `tail/2` returns a bounded byte/line page with truncation
  and backward paging metadata. See `docs/background.md` for controls and limitations.
  """
  use GenServer

  @poll_ms 20
  @owner_ms 100
  @startup_ms 5_000
  @max_tail_bytes 1_000_000
  @start_options [:owner, :cwd, :root, :timeout, :env]

  @doc "Start without linking to the caller. Returns {:ok, pid, id} or {:error, reason}."
  def start(command, opts \\ []) do
    with :ok <- validate_start(command, opts),
         {:ok, executables} <- executables() do
      id = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

      case GenServer.start(__MODULE__, {command, opts, id, self(), executables}) do
        {:ok, pid} -> {:ok, pid, id}
        error -> error
      end
    end
  rescue
    e -> {:error, {:start, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:start, reason}}
  end

  @doc "Request whole process-group SIGKILL. The first cancellation/timeout wins."
  def cancel(pid), do: safe_call(pid, :cancel)

  @doc "Current info map, or {:error, reason} for a dead/invalid worker."
  def info(pid), do: safe_call(pid, :info)

  @doc "Read completed result.json by owner and job ID; string-keyed map, or {:error, reason}."
  def result(owner, id, opts \\ []) do
    cond do
      not valid_owner?(owner) ->
        {:error, :invalid_owner}

      not valid_owner?(id) ->
        {:error, :invalid_id}

      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      Keyword.keys(opts) -- [:root] != [] ->
        {:error, :unknown_option}

      not valid_text?(Keyword.get(opts, :root, "/data/background")) ->
        {:error, {:invalid_option, :root}}

      true ->
        path =
          Path.join([
            Path.expand(Keyword.get(opts, :root, "/data/background")),
            owner,
            id,
            "result.json"
          ])

        with {:ok, page} <- tail(path, bytes: 64_000, lines: 1_000) do
          if page.truncated do
            {:error, :result_too_large}
          else
            case Jason.decode(page.text) do
              {:ok, data} when is_map(data) -> {:ok, data}
              _ -> {:error, :invalid_result}
            end
          end
        end
    end
  rescue
    e -> {:error, {:result, Exception.message(e)}}
  end

  defp safe_call(pid, request) when is_pid(pid) and node(pid) == node() do
    GenServer.call(pid, request, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, reason -> {:error, {:call, reason}}
  end

  defp safe_call(_, _), do: {:error, :invalid_pid}

  @doc """
  Read at most `bytes + 1` bytes, returning at most `bytes` bytes and `lines` lines.
  Defaults: bytes: 12000, lines: 100. `before` is an exclusive byte offset (default EOF).
  Pass the returned `next_before` as `before` to page backwards. Data is raw bytes:
  a very long line or multibyte character can be cut, announced by partial_first_line.
  """
  def tail(path, opts \\ []) do
    with :ok <- validate_tail(path, opts),
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, size} <- :file.position(file, :eof) do
          before = Keyword.get(opts, :before, size)

          if before <= size do
            tail_page(file, size, before, opts)
          else
            {:error, {:offset_past_end, size}}
          end
        end
      after
        :file.close(file)
      end
    end
  rescue
    e -> {:error, {:tail, Exception.message(e)}}
  end

  defp tail_page(file, size, before, opts) do
    cap = Keyword.get(opts, :bytes, 12_000)
    limit = Keyword.get(opts, :lines, 100)
    start = max(0, before - cap - 1)

    case :file.pread(file, start, before - start) do
      :eof ->
        {:ok, page("", size, before, false)}

      {:ok, data} ->
        skip = max(0, byte_size(data) - cap)
        suffix = binary_part(data, skip, byte_size(data) - skip)
        breaks = :binary.matches(suffix, "\n")
        # A final newline terminates the last line; it is not an extra empty line.
        breaks = if String.ends_with?(suffix, "\n"), do: Enum.drop(breaks, -1), else: breaks
        cut = if length(breaks) >= limit, do: elem(Enum.at(breaks, -limit), 0) + 1, else: 0
        text = binary_part(suffix, cut, byte_size(suffix) - cut)
        offset = start + skip + cut

        partial =
          offset > 0 and cut == 0 and (skip == 0 or binary_part(data, skip - 1, 1) != "\n")

        {:ok, page(text, size, offset, partial)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page(text, size, offset, partial) do
    %{
      text: text,
      bytes: byte_size(text),
      total_bytes: size,
      offset: offset,
      next_before: if(offset > 0, do: offset, else: nil),
      truncated: offset > 0 or offset + byte_size(text) < size,
      partial_first_line: partial
    }
  end

  defp validate_tail(path, opts) do
    cond do
      not valid_text?(path) ->
        {:error, :invalid_path}

      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      Keyword.keys(opts) -- [:bytes, :lines, :before] != [] ->
        {:error, :unknown_option}

      not positive_limit?(Keyword.get(opts, :bytes, 12_000), @max_tail_bytes) ->
        {:error, {:invalid_option, :bytes}}

      not positive_limit?(Keyword.get(opts, :lines, 100), 100_000) ->
        {:error, {:invalid_option, :lines}}

      not nonnegative?(Keyword.get(opts, :before, 0)) ->
        {:error, {:invalid_option, :before}}

      true ->
        :ok
    end
  end

  defp validate_start(command, opts) do
    cond do
      not valid_text?(command) ->
        {:error, :invalid_command}

      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      Keyword.keys(opts) -- @start_options != [] ->
        {:error, :unknown_option}

      not valid_owner?(Keyword.get(opts, :owner)) ->
        {:error, :invalid_owner}

      not valid_text?(Keyword.get(opts, :cwd, "/app")) ->
        {:error, {:invalid_option, :cwd}}

      not valid_text?(Keyword.get(opts, :root, "/data/background")) ->
        {:error, {:invalid_option, :root}}

      not valid_timeout?(Keyword.get(opts, :timeout, 3_600_000)) ->
        {:error, {:invalid_option, :timeout}}

      not valid_env?(Keyword.get(opts, :env, [])) ->
        {:error, {:invalid_option, :env}}

      true ->
        :ok
    end
  end

  defp valid_text?(text),
    do:
      is_binary(text) and byte_size(text) > 0 and String.valid?(text) and
        not String.contains?(text, <<0>>)

  defp valid_owner?(name),
    do:
      valid_text?(name) and byte_size(name) <= 128 and name not in [".", ".."] and
        Regex.match?(~r/^[a-zA-Z0-9_.-]+$/, name)

  defp nonnegative?(n), do: is_integer(n) and n >= 0
  defp positive_limit?(n, max), do: is_integer(n) and n > 0 and n <= max
  defp valid_timeout?(:infinity), do: true
  defp valid_timeout?(n), do: nonnegative?(n) and n <= 4_294_967_295

  defp valid_env?(env) when is_list(env) do
    Enum.all?(env, fn
      {key, value} ->
        valid_text?(key) and not String.contains?(key, "=") and is_binary(value) and
          String.valid?(value) and not String.contains?(value, <<0>>)

      _ ->
        false
    end)
  end

  defp valid_env?(_), do: false

  defp executables do
    Enum.reduce_while(["sh", "setsid", "kill", "mv", "sleep"], {:ok, %{}}, fn name,
                                                                              {:ok, found} ->
      case System.find_executable(name) do
        nil -> {:halt, {:error, {:missing_executable, name}}}
        path -> {:cont, {:ok, Map.put(found, name, path)}}
      end
    end)
  end

  @impl true
  def init({command, opts, id, caller, executables}) do
    owner = Keyword.fetch!(opts, :owner)
    Process.put(:"$callers", [NanoAgent.whereis(owner) || caller])
    Process.flag(:trap_exit, true)
    dir = Path.join([Path.expand(Keyword.get(opts, :root, "/data/background")), owner, id])
    cwd = Path.expand(Keyword.get(opts, :cwd, "/app"))

    with {:ok, %{type: :directory}} <- File.stat(cwd),
         :ok <- File.mkdir_p(dir),
         output = Path.join(dir, "output.log"),
         :ok <- File.write(output, ""),
         {:ok, port} <- open_port(command, dir, cwd, opts, executables) do
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      timeout = Keyword.get(opts, :timeout, 3_600_000)
      timer = if timeout not in [:infinity, 0], do: Process.send_after(self(), :timeout, timeout)

      s = %{
        id: id,
        owner: owner,
        output: output,
        cwd: cwd,
        port: port,
        os_pid: os_pid,
        session_pid: nil,
        session_start: nil,
        timer: timer,
        reason: if(timeout == 0, do: :timeout, else: :exit),
        status: :running,
        phase: if(timeout == 0, do: :stopping, else: :starting),
        errors: [],
        started_at: System.system_time(:millisecond),
        startup_deadline: System.monotonic_time(:millisecond) + @startup_ms,
        kill_executable: executables["kill"]
      }

      s = persist(s, "metadata.json")
      send(self(), :session_ready)
      Process.send_after(self(), :refresh_owner, @owner_ms)
      {:ok, s}
    else
      {:ok, _} -> {:stop, {:startup, :cwd_not_directory}}
      {:error, reason} -> {:stop, {:startup, reason}}
    end
  rescue
    e -> {:stop, {:startup, Exception.message(e)}}
  end

  defp open_port(command, dir, cwd, opts, executables) do
    pid_path = Path.join(dir, "session.pid")
    gate = Path.join(dir, "go")
    quote = &Seedling.Tools.quote_arg/1
    # Never run user code before the worker knows the actual session ID. The PID
    # file is atomically published, and the gate expires if the worker dies at startup.
    inner =
      "printf '%s\\n' \"$$\" > " <>
        quote.(pid_path <> ".tmp") <>
        " && " <>
        quote.(executables["mv"]) <>
        " -- " <>
        quote.(pid_path <> ".tmp") <>
        " " <>
        quote.(pid_path) <>
        " || exit 125; n=0; while [ ! -f " <>
        quote.(gate) <>
        " ]; do " <>
        "n=$((n+1)); [ \"$n\" -lt 200 ] || exit 125; " <>
        quote.(executables["sleep"]) <>
        " 0.05; done; exec " <>
        quote.(executables["sh"]) <> " -c " <> quote.(command)

    script =
      "exec " <>
        quote.(executables["setsid"]) <>
        " --wait " <>
        quote.(executables["sh"]) <>
        " -c " <>
        quote.(inner) <>
        " > " <> quote.(Path.join(dir, "output.log")) <> " 2>&1"

    port =
      Port.open({:spawn_executable, executables["sh"]}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", script],
        cd: cwd,
        env:
          Enum.map(Keyword.get(opts, :env, []), fn {k, v} ->
            {String.to_charlist(k), String.to_charlist(v)}
          end)
      ])

    {:ok, port}
  rescue
    e -> {:error, {:port, Exception.message(e)}}
  end

  @impl true
  def handle_call(:info, _from, s) do
    refresh_owner(s)
    {:reply, public_info(s), s}
  end

  def handle_call(:cancel, _from, s), do: {:reply, :ok, request_kill(s, :cancelled)}

  @impl true
  def handle_info(:session_ready, %{status: :running, session_pid: nil} = s) do
    case File.read(Path.join(Path.dirname(s.output), "session.pid")) do
      {:ok, text} ->
        case Integer.parse(String.trim(text)) do
          {pid, ""} when pid > 1 ->
            s = %{s | session_pid: pid, session_start: session_identity(pid)}

            if s.reason == :exit do
              case File.write(Path.join(Path.dirname(s.output), "go"), "") do
                :ok -> {:noreply, persist(%{s | phase: :running}, "metadata.json")}
                {:error, reason} -> {:noreply, request_kill(add_error(s, :gate, reason), :error)}
              end
            else
              {:noreply, kill_group(s)}
            end

          _ ->
            {:noreply, request_kill(add_error(s, :session, :invalid_pid), :error)}
        end

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < s.startup_deadline do
          Process.send_after(self(), :session_ready, @poll_ms)
          {:noreply, s}
        else
          # Never guess a PGID from the port PID: setsid may have forked. The gate
          # exits on its own after 10s; keep polling for an eventual published PID.
          Process.send_after(self(), :session_ready, @poll_ms)
          {:noreply, request_kill(s, :error)}
        end

      {:error, reason} ->
        Process.send_after(self(), :session_ready, @poll_ms)
        {:noreply, request_kill(add_error(s, :session, reason), :error)}
    end
  end

  def handle_info(:session_ready, s), do: {:noreply, s}
  def handle_info(:timeout, s), do: {:noreply, request_kill(s, :timeout)}

  def handle_info(:kill_retry, %{status: :running, reason: reason} = s) when reason != :exit,
    do: {:noreply, kill_group(s)}

  def handle_info(:kill_retry, s), do: {:noreply, s}

  def handle_info(:refresh_owner, s) do
    refresh_owner(s)
    Process.send_after(self(), :refresh_owner, @owner_ms)
    {:noreply, s}
  end

  def handle_info({port, {:data, _}}, %{port: port} = s), do: {:noreply, s}

  def handle_info({port, {:exit_status, status}}, %{port: port, status: :running} = s),
    do: finish(s, status)

  def handle_info({:EXIT, port, reason}, %{port: port, status: :running} = s),
    do: finish(kill_group(add_error(%{s | reason: :error}, :port_exit, reason)), 125)

  def handle_info({:EXIT, port, _reason}, %{port: port} = s), do: {:noreply, s}

  def handle_info(:deliver, %{status: status} = s) when is_integer(status) do
    case NanoAgent.whereis(s.owner) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          refresh_owner(s)

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
        else
          retry_delivery(s)
        end

      nil ->
        retry_delivery(s)
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp retry_delivery(s) do
    Process.send_after(self(), :deliver, @owner_ms)
    {:noreply, s}
  end

  defp finish(s, status) do
    if s.timer, do: Process.cancel_timer(s.timer)
    s = persist(%{s | status: status, phase: :completed}, "result.json")
    send(self(), :deliver)
    {:noreply, s}
  end

  defp refresh_owner(s) do
    if pid = NanoAgent.whereis(s.owner), do: Process.put(:"$callers", [pid])
  end

  defp request_kill(%{status: :running, reason: :exit} = s, reason),
    do: kill_group(%{s | reason: reason, phase: :stopping})

  defp request_kill(s, _), do: s

  defp kill_group(%{session_pid: nil} = s), do: s

  defp kill_group(s) do
    if s.session_start != nil and session_identity(s.session_pid) == s.session_start do
      signal_group(s)
    else
      # The leader already exited (or its PID was reused). Never signal an
      # unrelated process group. The port will report the actual exit shortly.
      s
    end
  end

  defp session_identity(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_, fields] <- Regex.run(~r/^\d+ \(.*\) (.*)$/s, stat),
         fields = String.split(fields),
         true <- Enum.at(fields, 2) == to_string(pid),
         true <- Enum.at(fields, 3) == to_string(pid) do
      Enum.at(fields, 19)
    else
      _ -> nil
    end
  end

  defp signal_group(s) do
    case System.cmd(s.kill_executable, ["-KILL", "--", "-#{s.session_pid}"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        s

      {text, _} ->
        # ESRCH is normal if completion raced the cancellation. Other errors are
        # visible and retried; completion always waits for the port's exit status.
        if String.contains?(text, "No such process") do
          s
        else
          Process.send_after(self(), :kill_retry, 100)
          add_error(s, :kill, text)
        end
    end
  rescue
    e ->
      Process.send_after(self(), :kill_retry, 100)
      add_error(s, :kill, Exception.message(e))
  end

  @impl true
  def terminate(_reason, %{status: :running} = s) do
    # Ordinary GenServer stops get OS cleanup too. Brutal BEAM :kill cannot run
    # terminate/2; operators should use cancel/1 rather than killing the worker.
    if s.session_pid, do: kill_group(s)
    :ok
  end

  def terminate(_, _), do: :ok

  defp public_info(s),
    do:
      Map.take(s, [
        :id,
        :owner,
        :output,
        :cwd,
        :os_pid,
        :session_pid,
        :status,
        :reason,
        :phase,
        :started_at,
        :errors
      ])

  defp add_error(s, operation, reason),
    do: %{
      s
      | errors: Enum.take([%{operation: operation, reason: inspect(reason)} | s.errors], 10)
    }

  defp persist(s, filename) do
    path = Path.join(Path.dirname(s.output), filename)

    with {:ok, data} <- Jason.encode(public_info(s)),
         :ok <- File.write(path <> ".tmp", data),
         :ok <- File.rename(path <> ".tmp", path) do
      s
    else
      {:error, reason} -> add_error(s, :persist, reason)
    end
  end
end
