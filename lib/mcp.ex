defmodule MCP do
  @moduledoc """
  MCP tools, resources, prompts and push events from eval. Config: `/app/config/mcp.json`.
  Start with `MCP.servers()`, `MCP.connect("demo")`, then `MCP.discover("demo")`.
  `MCP.call_tool("demo", "echo", %{"text" => "hello"})`, `MCP.read_resource/2`,
  `MCP.get_prompt/3`, and `MCP.list/3` return `{:ok, result}` or `{:error, reason}`.
  Lists are one protocol page; pass `cursor:` from `nextCursor`. Results over 12 KB spill
  as JSON; use `MCP.page(path, offset: 0, bytes: 4000)` to read bounded byte pages.

  `MCP.subscribe("demo", "demo://value")` durably records intent for the current named
  agent. It returns `:ok` for saved intent, not a server acknowledgment; acknowledgment
  or failure arrives as `{:mcp, server, method, params}` in the agent mailbox. All attached
  agents receive notifications, including progress, log and list changes. Use
  `agent: "name"` explicitly outside an agent eval. `MCP.attach(name, [servers])` is the
  delegation startup interface; `MCP.unsubscribe/3` removes durable resource intent.

  Target revision: 2026-07-28 (read 2026-10-08), with legacy 2025-11-25/06-18/03-26 and
  2024-11-05 initialization. Current stdio probes and falls back; set `protocol_version`
  explicitly for legacy HTTP. Connections reconnect with capped exponential backoff;
  in-flight calls fail (never replay side effects); subscriptions are re-established.
  Agent names, not PIDs, are persisted under `/data/mcp`; names are resolved for each
  event, so an agent restart needs no reattach. Events during an absent agent are not
  replayed. Add `{MCP, []}` to the application supervisor for node-boot restoration.
  Without that hook, the first API call lazily restores saved connections.

  No OAuth flow, sampling, roots, elicitation, automatic tool execution, schema
  validation or MRTR automation. Input-required results are explicit errors with the
  payload; retry through `request/4` with operator-supplied inputResponses. Returned
  server text is untrusted data, never executable configuration. See `docs/mcp.md`.
  """
  use GenServer

  defp default_root do
    Application.get_env(:nano, :state_dir, "/data/state")
    |> Path.dirname()
    |> Path.join("mcp")
  end

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "List configured server names and transport; never exposes credentials."
  def servers(opts \\ []), do: call_manager(:servers, opts)

  def connect(server, opts \\ []) do
    with {:ok, agent} <- agent(opts),
         {:ok, _pid} <- call_manager({:connect, server, agent}, opts),
         do: await(server, opts)
  end

  def attach(agent, servers, opts \\ []) when is_binary(agent) and is_list(servers) do
    Enum.reduce_while(servers, :ok, fn server, :ok ->
      case call_manager({:connect, server, agent}, opts) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def status(server, opts \\ []) do
    case raw_status(server, opts) do
      %{info: info} = status ->
        case bounded({:ok, info}, opts) do
          {:ok, info} -> %{status | info: info}
          error -> error
        end

      error ->
        error
    end
  end

  defp raw_status(server, opts) do
    with {:ok, pid} <- call_manager({:connection, server}, opts),
         do: safe(fn -> MCP.Connection.status(pid) end)
  end

  def await(server, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 20_000)
    await_loop(server, opts, deadline)
  end

  defp await_loop(server, opts, deadline) do
    case status(server, opts) do
      %{ready: true} = status ->
        {:ok, status}

      %{ready: false} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          await_loop(server, opts, deadline)
        else
          {:error, :connect_timeout}
        end

      error ->
        error
    end
  end

  @doc "One discovery page per offered category; inspect nextCursor and use list/3 to continue."
  def discover(server, opts \\ []) do
    case raw_status(server, opts) do
      %{ready: true, info: info} ->
        caps = info["capabilities"] || %{}

        pages =
          for {kind, cap} <- [tools: "tools", resources: "resources", prompts: "prompts"],
              Map.has_key?(caps, cap),
              into: %{},
              do: {kind, list(server, kind, opts)}

        bounded({:ok, %{server: info, pages: pages}}, opts)

      %{ready: false} ->
        {:error, :not_ready}

      error ->
        error
    end
  end

  @doc "List :tools, :resources, :templates or :prompts; returns one server page."
  def list(server, kind, opts \\ []) do
    methods = %{
      tools: "tools/list",
      resources: "resources/list",
      templates: "resources/templates/list",
      prompts: "prompts/list"
    }

    case methods[kind] do
      nil ->
        {:error, :invalid_list_kind}

      method ->
        request(
          server,
          method,
          if(opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}),
          opts
        )
    end
  end

  def call_tool(server, name, arguments \\ %{}, opts \\ []),
    do: request(server, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  def read_resource(server, uri, opts \\ []),
    do: request(server, "resources/read", %{"uri" => uri}, opts)

  def get_prompt(server, name, arguments \\ %{}, opts \\ []),
    do: request(server, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)

  @doc "Low-level bounded JSON-RPC request; no automatic retry of calls with side effects."
  def request(server, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) do
    with {:ok, pid} <- call_manager({:connection, server}, opts) do
      safe(fn ->
        MCP.Connection.request(pid, method, params, Keyword.get(opts, :timeout, 15_000))
      end)
      |> bounded(opts)
    end
  end

  def subscribe(server, uri, opts \\ []), do: subscription(server, uri, true, opts)
  def unsubscribe(server, uri, opts \\ []), do: subscription(server, uri, false, opts)

  defp subscription(server, uri, enabled, opts) when is_binary(uri) do
    with {:ok, agent} <- agent(opts),
         do: call_manager({:subscription, server, agent, uri, enabled}, opts)
  end

  @doc "Detach this agent, removing its saved subscriptions. Other agents keep their connection."
  def detach(server, opts \\ []) do
    with {:ok, agent} <- agent(opts), do: call_manager({:detach, server, agent}, opts)
  end

  @doc "Read a spill file as a bounded byte page (base64 if a page is not UTF-8)."
  def page(path, opts \\ []) do
    offset = opts[:offset] || 0
    bytes = min(opts[:bytes] || 4000, 16_000)

    if is_integer(offset) and offset >= 0 and is_integer(bytes) and bytes > 0 do
      with {:ok, io} <- File.open(path, [:read, :binary]) do
        result = :file.pread(io, offset, bytes)
        File.close(io)

        case result do
          {:ok, data} ->
            {:ok,
             %{
               data: if(String.valid?(data), do: data, else: Base.encode64(data)),
               encoding: if(String.valid?(data), do: :utf8, else: :base64),
               next_offset: offset + byte_size(data)
             }}

          :eof ->
            {:ok, :eof}

          error ->
            error
        end
      end
    else
      {:error, :invalid_page}
    end
  end

  defp bounded({tag, data}, opts) when tag in [:ok, :error] do
    # Encode inspected local errors as strings; protocol results remain lossless JSON.
    encoded =
      case Jason.encode(data) do
        {:ok, text} ->
          text

        _ ->
          Jason.encode!(
            inspect(data, limit: :infinity, printable_limit: :infinity, width: :infinity)
          )
      end

    cap = min(max(opts[:bytes] || 12_000, 256), 32_000)

    if byte_size(encoded) <= cap do
      {tag, data}
    else
      dir = opts[:spill_dir] || Path.join(default_root(), "spill")

      path =
        Path.join(
          dir,
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".json"
        )

      with :ok <- File.mkdir_p(dir), :ok <- File.write(path, encoded) do
        {tag,
         %{
           truncated: true,
           bytes: byte_size(encoded),
           path: path,
           preview: byte_preview(encoded, div(cap, 4)),
           continue: "MCP.page(path, offset: 0, bytes: 4000)"
         }}
      end
    end
  end

  defp bounded(other, _), do: other

  defp byte_preview(data, cap) do
    prefix = binary_part(data, 0, min(cap, byte_size(data)))
    utf8_prefix(prefix)
  end

  defp utf8_prefix(<<>>), do: ""

  defp utf8_prefix(data) do
    if String.valid?(data), do: data, else: utf8_prefix(binary_part(data, 0, byte_size(data) - 1))
  end

  @doc "Remove all durable attachments for a named agent (delegation startup rollback)."
  def detach_agent(agent, opts \\ []) when is_binary(agent),
    do: call_manager({:detach_agent, agent}, opts)

  defp agent(opts) do
    case opts[:agent] do
      name when is_binary(name) and byte_size(name) > 0 -> {:ok, name}
      nil -> Delegation.caller_name()
      _ -> {:error, :agent_must_be_a_name}
    end
  end

  defp call_manager(message, opts) do
    manager = opts[:manager] || __MODULE__

    if manager == __MODULE__ and Process.whereis(__MODULE__) == nil do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        error -> throw(error)
      end
    end

    safe(fn -> GenServer.call(manager, message) end)
  catch
    error -> error
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:process_unavailable, inspect(reason, limit: 10)}}
  end

  def init(opts) do
    root = opts[:state_dir] || default_root()
    config_path = opts[:config_path] || "/app/config/mcp.json"

    path = Path.join(root, "subscriptions.json")

    with {:ok, config} <- MCP.Config.load(config_path),
         :ok <- File.mkdir_p(root),
         {:ok, saved} <- load_records(path) do
      send(self(), :restore)

      {:ok,
       %{
         config: config,
         records: saved,
         path: path,
         root: root,
         connections: %{},
         deliver: opts[:deliver] || (&default_deliver/2)
       }}
    else
      error -> {:stop, error}
    end
  end

  def handle_call(:servers, _, s),
    do:
      {:reply,
       {:ok,
        Map.new(s.config, fn {name, c} ->
          {name, %{transport: c["transport"], protocol_version: c["protocol_version"] || "auto"}}
        end)}, s}

  def handle_call({:connection, name}, _, s),
    do:
      {:reply,
       case s.connections[name] do
         nil -> {:error, :not_connected}
         pid -> {:ok, pid}
       end, s}

  def handle_call({:connect, name, agent}, _, s) do
    if Map.has_key?(s.config, name) do
      records = Map.update(s.records, name, %{agent => []}, &Map.put_new(&1, agent, []))

      case persist(%{s | records: records}) do
        :ok ->
          s = ensure_connection(%{s | records: records}, name)
          {:reply, {:ok, s.connections[name]}, s}

        error ->
          {:reply, error, s}
      end
    else
      {:reply, {:error, :unknown_server}, s}
    end
  end

  def handle_call({:subscription, name, agent, uri, enabled}, _, s) do
    if Map.has_key?(s.config, name) do
      agents = s.records[name] || %{}
      uris = agents[agent] || []
      uris = if enabled, do: Enum.uniq([uri | uris]), else: List.delete(uris, uri)
      records = Map.put(s.records, name, Map.put(agents, agent, uris))

      case persist(%{s | records: records}) do
        :ok ->
          s = ensure_connection(%{s | records: records}, name)
          MCP.Connection.subscriptions(s.connections[name], all_uris(s, name))
          {:reply, :ok, s}

        error ->
          {:reply, error, s}
      end
    else
      {:reply, {:error, :unknown_server}, s}
    end
  end

  def handle_call({:detach_agent, agent}, from, s) do
    names = for {name, agents} <- s.records, Map.has_key?(agents, agent), do: name

    Enum.reduce_while(names, {:reply, :ok, s}, fn name, {:reply, :ok, s} ->
      case handle_call({:detach, name, agent}, from, s) do
        {:reply, :ok, next} -> {:cont, {:reply, :ok, next}}
        other -> {:halt, other}
      end
    end)
  end

  def handle_call({:detach, name, agent}, _, s) do
    agents = Map.delete(s.records[name] || %{}, agent)

    records =
      if map_size(agents) == 0,
        do: Map.delete(s.records, name),
        else: Map.put(s.records, name, agents)

    case persist(%{s | records: records}) do
      :ok ->
        s = %{s | records: records}

        if s.connections[name] do
          if map_size(agents) == 0 do
            GenServer.stop(s.connections[name])
            {:reply, :ok, %{s | connections: Map.delete(s.connections, name)}}
          else
            MCP.Connection.subscriptions(s.connections[name], all_uris(s, name))
            {:reply, :ok, s}
          end
        else
          {:reply, :ok, s}
        end

      error ->
        {:reply, error, s}
    end
  end

  def handle_info(:restore, s) do
    {:noreply,
     Enum.reduce(Map.keys(s.records), s, fn name, s ->
       if Map.has_key?(s.config, name), do: ensure_connection(s, name), else: s
     end)}
  end

  def handle_info({:DOWN, _, :process, pid, reason}, s) do
    case Enum.find(s.connections, fn {_, p} -> p == pid end) do
      nil ->
        {:noreply, s}

      {name, _} ->
        Process.send_after(self(), :restore, 500)
        deliver(s, name, "client/connection_crashed", %{reason: inspect(reason, limit: 10)})
        {:noreply, %{s | connections: Map.delete(s.connections, name)}}
    end
  end

  def handle_info({:mcp_event, name, method, params}, s) do
    deliver(s, name, method, params)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s),
    do:
      Enum.each(s.connections, fn {_, pid} -> if Process.alive?(pid), do: GenServer.stop(pid) end)

  defp ensure_connection(s, name) do
    if s.connections[name] do
      s
    else
      {:ok, pid} = MCP.Connection.start(s.config[name], self(), name, all_uris(s, name))
      Process.monitor(pid)
      %{s | connections: Map.put(s.connections, name, pid)}
    end
  end

  defp all_uris(s, name),
    do: (s.records[name] || %{}) |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()

  defp load_records(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, json} ->
        with {:ok, data} when is_map(data) <- Jason.decode(json),
             true <-
               Enum.all?(data, fn {name, agents} ->
                 is_binary(name) and is_map(agents) and
                   Enum.all?(agents, fn {agent, uris} ->
                     is_binary(agent) and is_list(uris) and Enum.all?(uris, &is_binary/1)
                   end)
               end) do
          {:ok, data}
        else
          _ -> {:error, {:invalid_subscription_file, path}}
        end

      {:error, reason} ->
        {:error, {:subscription_file, reason}}
    end
  end

  defp persist(s) do
    temp = s.path <> ".tmp"
    with :ok <- File.write(temp, Jason.encode!(s.records)), do: File.rename(temp, s.path)
  end

  defp deliver(s, name, method, params) do
    bounded =
      case bounded({:ok, params}, spill_dir: Path.join(s.root, "spill"), bytes: 6000) do
        {:ok, data} -> data
        {:error, reason} -> %{event_output_error: inspect(reason, limit: 10)}
      end

    for agent <- Map.keys(s.records[name] || %{}),
        do: s.deliver.(agent, {:mcp, name, method, bounded})

    :ok
  end

  defp default_deliver(agent, event) do
    if pid = NanoAgent.whereis(agent), do: send(pid, event)
    :ok
  end
end
