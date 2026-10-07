defmodule Seedling.Delegation do
  @moduledoc """
  Isolated-context jobs. `subagent(name, prompt: brief, notify: parent_name, pre: paths)`
  returns `{:ok, handle}`. Child calls `report(reply_to, ref, result)`; parent receives
  `{:delegation_done, ref, name, result}` or `{:delegation_failed, ref, name, reason}`.
  See seedings/DELEGATION_USAGE.md. Watchers survive agent restarts, not node restarts.
  """
  @agent_keys [:model, :reasoning, :max_turns, :max_tokens, :max_context]

  def subagent(name, opts \\ []) do
    owner = Keyword.get(opts, :notify, parent())
    ref = make_ref()

    watcher =
      spawn(fn ->
        receive do
          {:watch, handle, owner} -> watch(handle, owner)
        end
      end)

    result =
      try do
        with {:ok, pre} <- preread(Keyword.get(opts, :pre, []), opts),
             {:ok, tree} <- worktree(opts[:worktree]),
             {:ok, servers} <- setup_mcp(Keyword.get(opts, :mcp, []), name),
             {:ok, template} <-
               compose(Keyword.put(opts, :mcp_names, servers), pre, tree, watcher, ref),
             {:ok, pid} <-
               NanoAgent.start(
                 [name: name, system_prompt: template, start_idle: true] ++
                   Keyword.take(opts, @agent_keys)
               ) do
          handle = %{
            name: name,
            pid: pid,
            ref: ref,
            reply_to: watcher,
            worktree: tree,
            mcp: servers,
            pre: Enum.map(pre, &Map.delete(&1, :text))
          }

          send(watcher, {:watch, handle, owner})

          if opts[:message] != nil,
            do:
              send(pid, %{
                message: opts[:message],
                sender_pid: resolve(owner),
                delegation_ref: ref,
                reply_to: watcher
              })

          if opts[:start_idle] == false and opts[:message] == nil,
            do:
              send(pid, %{
                message: "Begin the job in your system prompt.",
                sender_pid: resolve(owner),
                delegation_ref: ref,
                reply_to: watcher
              })

          {:ok, handle}
        end
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:setup_exit, reason}}
      end

    case result do
      {:ok, _} ->
        result

      error ->
        Process.exit(watcher, :kill)
        error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def report(reply_to, ref, result),
    do: send(reply_to, {:delegation_report, ref, resolve(parent()), result})

  def await(%{ref: ref}, timeout \\ 60_000) do
    receive do
      {:delegation_done, ^ref, _, result} -> {:ok, result}
      {:delegation_failed, ^ref, _, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  def preread(paths, opts \\ []) do
    cap = Keyword.get(opts, :pre_max_bytes, 24_000)
    per = Keyword.get(opts, :pre_file_bytes, 8_000)

    if not (is_integer(cap) and cap in 1..96_000 and is_integer(per) and per in 1..24_000 and
              is_list(paths) and length(paths) <= 32) do
      {:error, :invalid_preread_limits}
    else
      Enum.reduce_while(paths, {:ok, [], cap}, fn path, {:ok, acc, left} ->
        case snapshot(path, min(per, left)) do
          {:ok, item} -> {:cont, {:ok, acc ++ [item], left - byte_size(item.text)}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items, _} -> {:ok, items}
        error -> error
      end
    end
  end

  defp snapshot(path, cap) do
    with {:ok, stat} <- File.stat(path),
         :ok <- readable(stat),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        {hash, size, head} = hash_read(io, :crypto.hash_init(:sha256), 0, "", cap)

        text =
          case :unicode.characters_to_binary(head) do
            value when is_binary(value) -> value
            {_, valid, _} -> valid
          end

        {:ok,
         %{
           path: Path.expand(path),
           sha256: Base.encode16(hash, case: :lower),
           bytes: size,
           text: text,
           truncated: byte_size(text) < size
         }}
      after
        File.close(io)
      end
    else
      {:error, reason} -> {:error, {:preread, path, reason}}
    end
  rescue
    e -> {:error, {:preread, path, Exception.message(e)}}
  end

  defp readable(%{type: :regular, size: size}) when size <= 64_000_000, do: :ok
  defp readable(%{type: :regular}), do: {:error, :file_too_large}
  defp readable(_), do: {:error, :not_regular_file}

  defp hash_read(io, hash, size, head, cap) do
    case IO.binread(io, 65_536) do
      :eof ->
        {:crypto.hash_final(hash), size, head}

      {:error, reason} ->
        raise "preread failed: #{inspect(reason)}"

      chunk when size + byte_size(chunk) > 64_000_000 ->
        raise "preread exceeds 64 MB streamed limit"

      chunk ->
        hash_read(
          io,
          :crypto.hash_update(hash, chunk),
          size + byte_size(chunk),
          head <> binary_part(chunk, 0, min(byte_size(chunk), max(0, cap - byte_size(head)))),
          cap
        )
    end
  end

  def compose(opts, pre, tree, watcher, _ref) do
    file = Application.get_env(:nano, :system_prompt_file) || "/app/priv/system_prompt.txt"

    with {:ok, facts} <- File.read(file) do
      readings =
        Enum.map_join(pre, "\n", fn p ->
          "Preread #{p.path} SHA256=#{p.sha256} bytes=#{p.bytes} truncated=#{p.truncated}\n" <>
            p.text
        end)

      {:ok,
       Enum.join(
         [
           facts,
           "Identity: " <> Keyword.get(opts, :identity, "Implementation specialist."),
           "Defend your context: delegate large work; hand over around half context, leaving space to report.",
           "Job: " <> Keyword.get(opts, :prompt, ""),
           "Working copy: #{tree || "none; shared /app"}. A worktree does not change eval's cwd; pass explicit paths/cwd.",
           "Report with Seedling.Delegation.report_job(#{inspect(watcher |> :erlang.pid_to_list() |> to_string())}, result). Protocol details: /app/seedings/DELEGATION_USAGE.md.",
           "MCP servers ready: #{inspect(Keyword.get(opts, :mcp_names, []))}. Use Seedling.MCP via eval; see /app/seedings/MCP_USAGE.md.",
           readings
         ],
         "\n\n"
       )}
    end
  end

  def report_job(reply_address, result),
    do:
      send(
        :erlang.list_to_pid(String.to_charlist(reply_address)),
        {:job_report, resolve(parent()), result}
      )

  defp worktree(nil), do: {:ok, nil}

  defp worktree(opts) when is_list(opts) do
    path =
      Keyword.get(
        opts,
        :path,
        "/data/seedling/worktrees/job-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    repo = Keyword.get(opts, :repo, "/app")
    revision = Keyword.get(opts, :revision, "HEAD")

    case System.cmd("git", ["-C", repo, "worktree", "add", "--detach", path, revision],
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, path}
      {output, status} -> {:error, {:worktree, status, String.slice(output, 0, 2000)}}
    end
  end

  defp worktree(_), do: {:error, :invalid_worktree}

  defp parent do
    case Process.get(:"$callers", []) do
      [pid | _] ->
        case Enum.find(Registry.keys(Nano.Registry, pid), &match?({:agent, _}, &1)) do
          {:agent, name} -> name
          _ -> pid
        end

      _ ->
        self()
    end
  end

  defp resolve(name) when is_binary(name), do: NanoAgent.whereis(name)
  defp resolve(pid), do: pid

  defp watch(handle, owner) do
    monitor = Process.monitor(handle.pid)
    loop(handle, owner, monitor)
  end

  defp loop(h, owner, monitor) do
    receive do
      {:delegation_report, ref, pid, result} when ref == h.ref and pid == h.pid ->
        deliver(owner, {:delegation_done, h.ref, h.name, result}, 600)

      {:job_report, pid, result} when pid == h.pid ->
        deliver(owner, {:delegation_done, h.ref, h.name, result}, 600)

      {:DOWN, ^monitor, :process, _, reason} ->
        deliver(owner, {:delegation_failed, h.ref, h.name, {:exit, reason}}, 600)

      _ ->
        loop(h, owner, monitor)
    after
      100 ->
        case safe_info(h.name) do
          %{halted: reason} when not is_nil(reason) ->
            deliver(owner, {:delegation_failed, h.ref, h.name, {:halted, reason}}, 600)

          _ ->
            loop(h, owner, monitor)
        end
    end
  end

  defp safe_info(name) do
    NanoAgent.info(name)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp setup_mcp([], _name), do: {:ok, []}

  defp setup_mcp(servers, name) when is_list(servers) do
    if Code.ensure_loaded?(Seedling.MCP) do
      Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, names} ->
        {server_name, result} =
          case server do
            {n, config} when is_binary(n) and is_map(config) ->
              {n, apply(Seedling.MCP, :connect, [n, config, [notify: name]])}

            n when is_binary(n) ->
              {n, apply(Seedling.MCP, :listen, [n, name])}

            _ ->
              {nil, {:error, :invalid_mcp_server}}
          end

        case result do
          :ok -> {:cont, {:ok, names ++ [server_name]}}
          {:ok, _} -> {:cont, {:ok, names ++ [server_name]}}
          error -> {:halt, {:error, {:mcp, server_name, error}}}
        end
      end)
    else
      {:error, :mcp_unavailable}
    end
  end

  defp setup_mcp(_, _), do: {:error, :invalid_mcp_servers}

  defp deliver(owner, message, attempts) do
    case resolve(owner) do
      pid when is_pid(pid) ->
        send(pid, message)

      _ when attempts > 0 ->
        Process.sleep(100)
        deliver(owner, message, attempts - 1)

      _ ->
        :undelivered
    end
  end
end
