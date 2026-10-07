defmodule Nano.MCP do
  @moduledoc """
  Speak the Model Context Protocol: connect servers, use their tools, resources and prompts,
  and receive what they push as ordinary mailbox events. The seeding is `/app/seedings/mcp.md`.

      Nano.MCP.catalogue()                     # every connected server, its tools/resources/prompts
      Nano.MCP.connect("fs")                    # from /app/mcp.json
      Nano.MCP.connect("fs", ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/app"])
      Nano.MCP.call("fs", "read_text_file", %{"path" => "/app/NOTES.md"})
      Nano.MCP.read_resource("fs", "file:///app/NOTES.md")
      Nano.MCP.subscribe("fs", uri: "file:///app/NOTES.md")   # changes then arrive as events
      Nano.MCP.subscriptions()                  # what the calling agent subscribed to

  ## Protocol era

  The specification moved to per-request metadata in revision `2026-07-28`: every request
  carries `_meta` with `io.modelcontextprotocol/protocolVersion`, `clientInfo` and
  `clientCapabilities`, and a client learns a server's era with `server/discover`. Servers
  that predate it (`2025-11-25` and earlier) use the `initialize` handshake. This client
  speaks both: it probes with `server/discover` and falls back to `initialize` on any error
  that is not a recognized modern error, exactly as the stdio binding's "Backward
  Compatibility" section prescribes. `Nano.MCP.servers() |> Nano.MCP.info(id)` reports which
  era and version a connection settled on.

  ## Configuration

  Servers in `/app/mcp.json` (`config_example/0` shows the shape), connectable by id:

      {"servers": {
         "fs": {"transport": "stdio", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/app"]},
         "remote": {"transport": "http", "url": "https://example.com/mcp", "headers": {"Authorization": "Bearer …"}}
       }}

  ## Events

  Notifications (`notifications/resources/updated`, `…/list_changed`, `notifications/message`,
  progress) are delivered to subscribed agents as mailbox events shaped

      {:mcp, %{server: "fs", method: "notifications/resources/updated", params: %{uri: "file:///…"}}}

  which the harness relays like anything else. Subscriptions are stored under
  `<data>/mcp_subscriptions.json` and re-established by `restore/1` after an agent restarts.
  """

  alias Nano.MCP.Store

  @doc "The protocol revision this client prefers."
  def protocol_version, do: "2026-07-28"

  @doc "Legacy revisions this client can fall back to."
  def legacy_versions, do: ["2025-11-25", "2025-06-18", "2025-03-26"]

  @doc "The bounds this module applies: `result_bytes`, `call_timeout`."
  def limits,
    do: %{result_bytes: Application.get_env(:nano, :mcp_result_bytes, 16_000), call_timeout: 120_000}

  ## Configuration

  @doc "The servers in `/app/mcp.json` (`MCP_CONFIG`), as `%{id => %{transport:, command:|url:, env:, headers:}}`."
  def config do
    path = System.get_env("MCP_CONFIG") || Path.join(Nano.Util.app_dir(), "mcp.json")

    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"servers" => servers}} when is_map(servers) -> Map.new(servers, fn {k, v} -> {k, normalize(v)} end)
          {:ok, other} when is_map(other) -> Map.new(other, fn {k, v} -> {k, normalize(v)} end)
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc "An example `/app/mcp.json` (also written by `Nano.MCP.write_example_config/0`)."
  def config_example do
    """
    {
      "servers": {
        "fs": {
          "transport": "stdio",
          "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/app"]
        },
        "remote": {
          "transport": "http",
          "url": "https://example.com/mcp",
          "headers": {}
        }
      }
    }
    """
  end

  @doc "Writes `config_example/0` to `/app/mcp.json` if it does not exist; returns the path."
  def write_example_config do
    path = Path.join(Nano.Util.app_dir(), "mcp.json")
    unless File.exists?(path), do: File.write!(path, config_example())
    path
  end

  defp normalize(c) when is_binary(c), do: %{transport: :http, url: c}
  defp normalize(c) when is_list(c), do: %{transport: :stdio, command: c, env: []}

  defp normalize(c) when is_map(c) do
    transport =
      case c["transport"] || c["type"] do
        "http" -> :http
        "streamable-http" -> :http
        "stdio" -> :stdio
        _ -> if c["url"], do: :http, else: :stdio
      end

    %{transport: transport, command: c["command"], url: c["url"], env: c["env"] || [], headers: c["headers"] || %{}, dir: c["dir"]}
  end

  ## Connecting

  @doc """
  Connects a server. `spec` may be an `mcp.json` id (default), a stdio `command` list, or an
  HTTP URL. Options: `agent:` (subscribe that agent to notifications), `env:`, `headers:`.
  Returns `{:ok, info}` with `era`, `protocolVersion`, `serverInfo` and `capabilities`.
  """
  def connect(id, spec \\ nil, opts \\ []) do
    with {:ok, config} <- resolve_config(id, spec, opts),
         {:ok, pid} <- start_server(id, config) do
      case Keyword.get(opts, :agent) do
        nil -> :ok
        agent -> subscribe(id, agent: agent)
      end

      case await_era(pid, Keyword.get(opts, :await, 15_000)) do
        {:ok, info} -> {:ok, info}
        :timeout -> {:error, :timeout}
      end
    end
  end

  defp await_era(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop_era(pid, deadline)
  end

  defp loop_era(pid, deadline) do
    info =
      try do
        GenServer.call(pid, :info, 5_000)
      catch
        :exit, _ -> %{connected: false}
      end

    cond do
      info.connected -> {:ok, info}
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true ->
        Process.sleep(100)
        loop_era(pid, deadline)
    end
  end

  @doc "Connects every server in `mcp.json`: `%{id => {:ok, info} | {:error, reason}}`."
  def connect_all, do: Map.new(config(), fn {id, _} -> {id, connect(id)} end)

  @doc "Stops a connection (it reconnects if it is still in `mcp.json`); a no-op if not connected."
  def disconnect(id) do
    case whereis(id) do
      nil -> {:error, :not_connected}
      pid -> DynamicSupervisor.terminate_child(Nano.MCP.Supervisor, pid) && :ok
    end
  end

  @doc "Ids of connected servers, sorted."
  def servers do
    Registry.select(Nano.MCP.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.map(&to_string/1) |> Enum.sort()
  end

  @doc "One server's connection info (era, version, serverInfo, capabilities), or nil."
  def info(id) do
    case whereis(id) do
      nil -> nil
      pid -> GenServer.call(pid, :info)
    end
  end

  defp start_server(id, config) do
    case whereis(id) do
      nil ->
        case DynamicSupervisor.start_child(Nano.MCP.Supervisor, {Nano.MCP.Server, {to_string(id), config}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp resolve_config(id, nil, _opts) do
    case config()[to_string(id)] do
      nil -> {:error, {:unknown_server, id, Map.keys(config())}}
      c -> {:ok, c}
    end
  end

  defp resolve_config(_id, command, opts) when is_list(command) and command != [] do
    if Keyword.keyword?(command) and (command[:command] || command[:url]) do
      if command[:command],
        do: {:ok, %{transport: :stdio, command: command[:command], env: command[:env] || []}},
        else: {:ok, %{transport: :http, url: command[:url], headers: command[:headers] || %{}}}
    else
      {:ok, %{transport: :stdio, command: command, env: Keyword.get(opts, :env, [])}}
    end
  end

  defp resolve_config(_id, url, opts) when is_binary(url),
    do: {:ok, %{transport: :http, url: url, headers: Keyword.get(opts, :headers, %{})}}

  defp resolve_config(_id, spec, _opts), do: {:error, {:bad_spec, spec}}

  defp whereis(id) do
    case Registry.lookup(Nano.MCP.Registry, to_string(id)) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp fetch(id) do
    case whereis(id) do
      nil -> {:error, {:not_connected, id, servers()}}
      pid -> {:ok, pid}
    end
  end

  ## Using what servers offer

  @doc """
  Everything connected, in one call: `%{id => %{era:, protocolVersion:, serverInfo:, tools:,
  resources:, prompts:, …}}`. This is the breadcrumb: one call to learn what is available.
  """
  def catalogue do
    Map.new(servers(), fn id ->
      case whereis(id) do
        nil -> {id, %{error: :not_connected}}
        pid ->
          info = GenServer.call(pid, :info)
          {tools, resources, prompts} = GenServer.call(pid, :catalogue)
          {id, Map.merge(info, %{tools: tools, resources: resources, prompts: prompts})}
      end
    end)
  end

  @doc "The catalogue as short lines, ready to read."
  def summary do
    case catalogue() do
      c when map_size(c) == 0 ->
        ["no MCP servers connected. Nano.MCP.connect(\"fs\") reads /app/mcp.json; Nano.MCP.write_example_config() writes one."]

      c ->
        Enum.map(c, fn {id, s} ->
          "#{id} (#{s.transport}, #{s.era || "connecting"}, #{s.protocolVersion || "?"}) " <>
            "#{length(s.tools || [])} tools, #{length(s.resources || [])} resources, #{length(s.prompts || [])} prompts" <>
            if(s.serverInfo, do: " — #{s.serverInfo["name"]} #{s.serverInfo["version"]}", else: "")
        end)
    end
  end

  @doc "A server's tools: `[%{name:, description:, inputSchema:}]`."
  def tools(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :tools))

  @doc "A server's resources: `[%{uri:, name:, description:, mimeType:}]`."
  def resources(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :resources))

  @doc "A server's resource templates."
  def resource_templates(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :resource_templates, 60_000))

  @doc "A server's prompts: `[%{name:, description:, arguments:}]`."
  def prompts(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :prompts, 60_000))

  @doc """
  Calls a tool. `args` is a map. `{:ok, result}` or `{:error, reason}`, where `result` is
  `%{content: [...], isError: bool, text: "..."}` and `text` joins the text parts.
  """
  def call(id, tool, args \\ %{}, opts \\ []) do
    with {:ok, pid} <- fetch(id) do
      GenServer.call(pid, {:call_tool, tool, args}, Keyword.get(opts, :timeout, limits().call_timeout))
    end
  end

  @doc "Reads a resource: `{:ok, %{contents: [...], text: ...}}`."
  def read_resource(id, uri) do
    with {:ok, pid} <- fetch(id), do: GenServer.call(pid, {:read_resource, uri}, limits().call_timeout)
  end

  @doc "Gets a prompt rendered by the server: `{:ok, %{description:, messages: [...]}}`."
  def get_prompt(id, name, args \\ %{}) do
    with {:ok, pid} <- fetch(id), do: GenServer.call(pid, {:get_prompt, name, args}, limits().call_timeout)
  end

  @doc "Pings a server; `{:ok, %{}}` when it answers."
  def ping(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :ping))

  @doc "Answers an arbitrary MCP request, e.g. `request(\"fs\", \"resources/templates/list\")`."
  def request(id, method, params \\ %{}) do
    with {:ok, pid} <- fetch(id), do: GenServer.call(pid, {:request, method, params}, limits().call_timeout)
  end

  ## Subscriptions

  @doc """
  Subscribes the calling agent (or `agent:`) to a server's notifications; with `uri:`, also asks
  the server to watch that resource. Notifications then arrive as `{:mcp, %{…}}` events.
  """
  def subscribe(id, opts \\ []) do
    id = to_string(id)
    uri = Keyword.get(opts, :uri)

    if uri, do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, {:subscribe_resource, uri}))

    agents =
      cond do
        Keyword.get(opts, :all) -> NanoAgent.list()
        agent = Keyword.get(opts, :agent) -> List.wrap(agent)
        agent = Nano.Util.calling_agent() -> [agent]
        true -> raise("no agent to subscribe; pass agent: or all: true")
      end

    Enum.each(agents, fn agent -> Store.add(subscriber_name(agent), id, uri, agent) end)
    :ok
  end

  defp subscriber_name(name) when is_binary(name), do: name
  defp subscriber_name(pid) when is_pid(pid), do: inspect(pid)

  @doc "Unsubscribes the calling agent (`agent:`); with `uri:`, also tells the server to stop watching."
  def unsubscribe(id, opts \\ []) do
    id = to_string(id)
    agent = to_string(Keyword.get(opts, :agent) || Nano.Util.calling_agent() || "unknown")
    uri = Keyword.get(opts, :uri)

    if uri, do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, {:unsubscribe_resource, uri}))

    Store.remove(agent, id, uri)
    :ok
  end

  @doc "The subscriptions of `agent` (default: the caller): `[%{agent:, server:, uri:}]`."
  def subscriptions(agent \\ nil), do: Store.list(agent || Nano.Util.calling_agent())

  @doc """
  Re-establishes an agent's subscriptions after a restart (re-sends resource watches to the
  servers that are up). Returns how many were re-sent.
  """
  def restore(agent) do
    for sub <- Store.list(agent), sub["uri"] && whereis(sub["server"]) != nil do
      with({:ok, pid} <- fetch(sub["server"]), do: GenServer.call(pid, {:subscribe_resource, sub["uri"]}))
    end
    |> Enum.count()
  end

  @doc "Delivers `message` to every agent subscribed to `server` (optionally filtered by `uri`)."
  def deliver(server, uri, message) do
    for sub <- Store.list(nil, server: server), uri == nil or sub["uri"] in [nil, uri] do
      case subscriber_pid(sub) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end

    :ok
  end

  defp subscriber_pid(sub) do
    # The recorded target is a pid for a process that subscribed itself, else an agent name.
    pid = parse_pid(sub["pid"])
    if pid && Process.alive?(pid), do: pid, else: NanoAgent.whereis(sub["agent"])
  end

  defp parse_pid(string) when is_binary(string) do
    case Regex.run(~r/#PID<(\d+)\.(\d+)\.(\d+)>/, string) do
      [_, a, b, c] -> :c.pid(String.to_integer(a), String.to_integer(b), String.to_integer(c))
      _ -> nil
    end
  end

  defp parse_pid(_), do: nil
end
