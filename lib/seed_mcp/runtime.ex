defmodule SeedMCP.Runtime do
  @moduledoc """
  Delegation integration without harness hooks.

      servers = [%{"name" => "files", "command" => "/usr/bin/mcp-files", "args" => []}]
      {:ok, handles} = SeedMCP.start_for("child", servers)
      SeedMCP.tools(handles["files"])
      # In the child's first turn, and after a child process restart:
      SeedMCP.handles("child")
      # After a node restart, before delivering the child's task:
      SeedMCP.restore("child")

  `start_for/3` returns only when every client is ready. Calls are supervised under
  a lazily started `SeedMCP.Supervisor` and named through the existing Nano.Names
  foundation. Each stable handle is `{:via, Nano.Names, {:mcp, owner, server}}`.
  No atoms are created from names. Starting an existing owner/server is idempotent.
  Owner names are resolved per event; child PID replacement needs no rebinding.

  `start_for` stores JSON runtime specs under `state_dir` (default
  `/data/seed_mcp`), with mode 0600. Specs can include headers/environment secrets;
  protect the directory. Configured names may instead refer to the checked-in
  `config:` file. Options such as config/state_dir/protocol must be passed again
  to `restore` by startup integration. For process restarts existing handles stay
  alive; for node restarts the parent must call restore before task delivery.

  Partial startup failure returns an error and stops all clients newly started
  by this invocation, leaving preexisting ones alone. Saved specs are retained
  for retry. A maximum of 50 specs is accepted. No external packages or global
  application settings are modified. `stop_for/1` ends an owner's clients, not
  their persisted intent.
  """
  def connect(spec, opts) do
    spec = Map.new(spec, fn {key, value} -> {to_string(key), value} end)
    owner = opts[:owner]
    name = spec["name"] || opts[:server_name]

    with true <- (is_pid(owner) or is_binary(owner)) and is_binary(name) and name != "",
         true <- spec["protocolVersion"] in [nil, "2025-11-25", "2026-07-28"],
         true <- opts[:protocol] in [nil, "2025-11-25", "2026-07-28"],
         {:ok, _} <- supervisor() do
      via = if is_binary(owner), do: {:via, Nano.Names, {:mcp, owner, name}}
      opts = Keyword.merge(opts, server: Map.delete(spec, "name"), server_name: name)
      opts = if via, do: Keyword.put(opts, :name, via), else: opts

      case DynamicSupervisor.start_child(SeedMCP.Supervisor, {SeedMCP, opts}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, bounded(reason)}
      end
    else
      false ->
        {:error,
         "MCP spec needs a name and PID/named owner; supported revisions: 2026-07-28, 2025-11-25"}

      error ->
        error
    end
  rescue
    e -> {:error, bounded(Exception.message(e))}
  end

  def start_for(owner, specs, opts \\ [])

  def start_for(owner, specs, opts) when is_binary(owner) and is_list(specs) do
    with true <- length(specs) <= 50 and Enum.all?(specs, &(is_binary(&1) or is_map(&1))),
         {:ok, encoded} <- Jason.encode(specs),
         true <- byte_size(encoded) <= 1_000_000,
         :ok <- persist(owner, encoded, opts) do
      initial = handles(owner)

      result =
        Enum.reduce_while(specs, {:ok, %{}, []}, fn spec, {:ok, map, started} ->
          name = if is_binary(spec), do: spec, else: spec["name"] || spec[:name]

          case SeedMCP.connect(spec, Keyword.put(opts, :owner, owner)) do
            {:ok, pid} ->
              started = if Map.has_key?(initial, name), do: started, else: [pid | started]

              case await_ready(pid, opts[:timeout] || 30_000) do
                {:ok, _} ->
                  {:cont,
                   {:ok, Map.put(map, name, {:via, Nano.Names, {:mcp, owner, name}}), started}}

                error ->
                  {:halt, {:failed, error, started}}
              end

            error ->
              {:halt, {:failed, error, started}}
          end
        end)

      case result do
        {:ok, map, _} ->
          {:ok, map}

        {:failed, error, started} ->
          Enum.each(started, &DynamicSupervisor.terminate_child(SeedMCP.Supervisor, &1))
          error
      end
    else
      false ->
        {:error, "Expected at most 50 server names/maps, with total configuration below 1MB"}

      {:error, reason} ->
        {:error, bounded(reason)}
    end
  rescue
    e -> {:error, bounded(Exception.message(e))}
  end

  def start_for(_, _, _),
    do: {:error, "Expected named owner and list of server names or map specs"}

  def restore(owner, opts \\ []) do
    with {:ok, bytes} <- File.read(config_path(owner, opts)),
         {:ok, specs} when is_list(specs) <- Jason.decode(bytes) do
      start_for(owner, specs, opts)
    else
      error -> {:error, bounded(error)}
    end
  end

  def handles(owner) do
    Nano.Names.all()
    |> Enum.reduce(%{}, fn
      {{:mcp, ^owner, name}, _}, acc ->
        Map.put(acc, name, {:via, Nano.Names, {:mcp, owner, name}})

      _, acc ->
        acc
    end)
  end

  def stop_for(owner) do
    Enum.each(handles(owner), fn {_, via} ->
      case GenServer.whereis(via) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(SeedMCP.Supervisor, pid)
      end
    end)

    :ok
  end

  def await_ready(client, timeout \\ 30_000) do
    if is_integer(timeout) and timeout > 0 do
      await(client, System.monotonic_time(:millisecond) + timeout)
    else
      {:error, "Positive ready timeout required"}
    end
  end

  defp await(client, deadline) do
    state = SeedMCP.status(client)

    cond do
      state.phase == :ready ->
        {:ok, state}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, "MCP readiness timed out"}

      true ->
        Process.sleep(20)
        await(client, deadline)
    end
  catch
    :exit, reason -> {:error, bounded(reason)}
  end

  defp supervisor() do
    case Process.whereis(SeedMCP.Supervisor) do
      nil ->
        case DynamicSupervisor.start_link(strategy: :one_for_one, name: SeedMCP.Supervisor) do
          {:ok, pid} ->
            Process.unlink(pid)
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          error ->
            error
        end

      pid ->
        {:ok, pid}
    end
  end

  defp persist(owner, bytes, opts) do
    path = config_path(owner, opts)
    temp = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, bytes),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path),
         do: :ok
  end

  defp config_path(owner, opts) do
    dir = opts[:state_dir] || "/data/seed_mcp"
    name = Base.url_encode64(:crypto.hash(:sha256, owner), padding: false)
    Path.join(dir, "owner-#{name}-servers.json")
  end

  defp bounded(error), do: inspect(error, limit: 8, printable_limit: 500)
end
