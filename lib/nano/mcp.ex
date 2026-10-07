defmodule Nano.MCP do
  @moduledoc """
  Speak the Model Context Protocol: connect MCP servers, use their tools, resources and
  prompts, and receive what they push as ordinary mailbox events. The seeding is
  `/app/seedings/mcp.md`; the protocol revision spoken is `protocol_version/0` (2025-06-18).

      Nano.MCP.catalogue()                            # every server, its tools/resources/prompts
      Nano.MCP.connect("fs", ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/app"])
      Nano.MCP.connect("remote", "https://example.com/mcp")
      Nano.MCP.servers()                              # ids of connected servers
      Nano.MCP.tools("fs")                            # [%{name:, description:, inputSchema:}]
      Nano.MCP.call("fs", "read_text_file", %{"path" => "/app/NOTES.md"})
      Nano.MCP.resources("fs")
      Nano.MCP.read_resource("fs", "file:///app/NOTES.md")
      Nano.MCP.prompts("fs")
      Nano.MCP.get_prompt("fs", "explain", %{"topic" => "OTP"})
      Nano.MCP.subscribe("fs", uri: "file:///app/NOTES.md")   # changes then arrive as events
      Nano.MCP.subscriptions()                                 # what this agent subscribed to

  ## Configuration

  Servers in `/app/mcp.json` (see `config_example/0`) are connectable by id; `connect_all/0`
  connects each:

      {"servers": {
         "fs": {"transport": "stdio", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/app"]},
         "remote": {"transport": "http", "url": "https://example.com/mcp", "headers": {"Authorization": "Bearer …"}}
       }}

  Or ad hoc: `connect("fs", ["npx", "-y", …])` for stdio, `connect("remote", "https://…")`
  for streamable HTTP, or `connect("fs", command: [...], env: [...], agent: "scout")`.

  ## Events

  Servers send notifications — `notifications/resources/updated`, `…/list_changed`,
  `notifications/tools/list_changed`, `notifications/message` (logging), progress on a long
  call — and an agent that subscribed receives them as mailbox events shaped

      {:mcp, %{server: "fs", method: "notifications/resources/updated", params: %{uri: "file:///…"}}}

  which the harness relays like anything else, so nothing new is in the harness: only a
  process that forwards them. Subscriptions are stored under `<data>/mcp_subscriptions.json`
  and re-established by `restore/1` after an agent restarts.

  ## Transports

  * **stdio**: the server is a subprocess; newline-delimited JSON-RPC on its stdin/stdout,
    its stderr kept in `<data>/mcp/<server>.stderr.log`. Connections are supervised and
    reconnect (with backoff) when the process exits.
  * **streamable HTTP**: every client message is a POST to the endpoint (`Accept:
    application/json, text/event-stream`); a POST may answer with JSON or with an SSE stream
    carrying the response and later notifications. `Mcp-Session-Id` and
    `MCP-Protocol-Version` headers are honoured.

  Results are plain Elixir terms: text comes back as text, binary payloads as references,
  everything capped at `limits().result_bytes`.
  """

  alias Nano.MCP.Store

  @protocol_version "2025-06-18"
  @limits %{result_bytes: 16_000, call_timeout: 120_000}

  @doc "The bounds this module applies: `result_bytes` and `call_timeout`."
  def limits, do: @limits

  @doc "The protocol revision this client speaks."
  def protocol_version, do: @protocol_version

  ## Configuration and connection

  @doc """
  The servers in `/app/mcp.json` (or the file named by `MCP_CONFIG`), as
  `%{id => %{transport:, command: | url:, env:, headers:}}`; `%{}` when there is no file.
  """
  def config do
    path = System.get_env("MCP_CONFIG") || Path.join(Nano.Util.app_dir(), "mcp.json")

    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"servers" => servers}} when is_map(servers) ->
            Map.new(servers, fn {k, v} -> {k, normalize(v)} end)

          {:ok, other} when is_map(other) ->
            Map.new(other, fn {k, v} -> {k, normalize(v)} end)

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  @doc "An example `/app/mcp.json`."
  def config_example do
    """
    {
      "servers": {
        "fs": {
          "transport": "stdio",
          "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/app"],
          "env": {}
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

  @doc """
  Connects a server. `server` is an id in `mcp.json`, or the id to register when `spec` is
  given:

    * `connect("fs")` — from `mcp.json`
    * `connect("fs", ["npx", "-y", "…"])` — stdio command
    * `connect("fs", "https://host/mcp")` — streamable HTTP URL
    * `connect("fs", command: [...], env: [{"K","V"}], agent: "scout")` — full form

  Options: `agent:` (also deliver this server's notifications to that agent, as a
  subscription), `env:`, `headers:`. Returns `{:ok, info}` with `serverInfo`, `capabilities`
  and `instructions`, or `{:error, reason}`.
  """
  def connect(id, spec \\ nil, opts \\ []) do
    with {:ok, config} <- resolve_config(id, spec, opts),
         {:ok, pid} <- start_server(id, config) do
      case Keyword.get(opts, :agent) do
        nil -> :ok
        agent -> subscribe(id, agent: agent)
      end

      # The handshake runs in the connection process; wait briefly for it so the returned
      # info is real (serverInfo, capabilities) rather than the empty pre-handshake map.
      case await_handshake(pid, Keyword.get(opts, :await, 10_000)) do
        {:ok, info} -> {:ok, info}
        :timeout -> {:error, :timeout}
      end
    end
  end

  defp await_handshake(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop_handshake(pid, deadline)
  end

  defp loop_handshake(pid, deadline) do
    info = GenServer.call(pid, :info)

    cond do
      info.protocolVersion != nil ->
        {:ok, info}

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(100)
        loop_handshake(pid, deadline)
    end
  end

  @doc "Connects every server in `mcp.json`. Returns `%{id => {:ok, info} | {:error, reason}}`."
  def connect_all do
    Map.new(config(), fn {id, _} -> {id, connect(id)} end)
  end

  @doc "Disconnects a server: stops its process. `/data`'s subscriptions are kept."
  def disconnect(id) do
    case whereis(id) do
      nil -> {:error, :not_connected}
      pid -> DynamicSupervisor.terminate_child(Nano.MCP.Supervisor, pid) && :ok
    end
  end

  @doc "Ids of connected servers."
  def servers do
    Registry.select(Nano.MCP.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp start_server(id, config) do
    case whereis(id) do
      nil ->
        case DynamicSupervisor.start_child(
               Nano.MCP.Supervisor,
               {Nano.MCP.Server, {to_string(id), config}}
             ) do
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
      %{} = c -> {:ok, c}
    end
  end

  defp resolve_config(_id, command, opts) when is_list(command) and command != [] do
    if Keyword.keyword?(command) and (command[:command] || command[:url]) do
      cond do
        command[:command] ->
          {:ok, %{transport: :stdio, command: command[:command], env: command[:env] || []}}

        true ->
          {:ok, %{transport: :http, url: command[:url], headers: command[:headers] || %{}}}
      end
    else
      {:ok, %{transport: :stdio, command: command, env: Keyword.get(opts, :env, [])}}
    end
  end

  defp resolve_config(_id, url, opts) when is_binary(url) do
    {:ok, %{transport: :http, url: url, headers: Keyword.get(opts, :headers, %{})}}
  end

  defp resolve_config(_id, spec, _opts), do: {:error, {:bad_spec, spec}}

  defp normalize(c) when is_binary(c), do: %{transport: :http, url: c}
  defp normalize(c) when is_list(c), do: %{transport: :stdio, command: c, env: []}

  defp normalize(c) when is_map(c) do
    transport =
      case c["transport"] || c["type"] do
        "http" -> :http
        "streamable-http" -> :http
        _ -> if c["url"], do: :http, else: :stdio
      end

    %{
      transport: transport,
      command: c["command"],
      url: c["url"],
      env: c["env"] || [],
      headers: c["headers"] || %{}
    }
  end

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
  Everything connected, in one call: `%{server_id => %{transport:, serverInfo:,
  capabilities:, instructions:, tools:, resources:, prompts:, connected_at:}}`; a server that
  is not connected reads `%{error: :not_connected}`.
  """
  def catalogue do
    Map.new(servers(), fn id ->
      case whereis(id) do
        nil ->
          {id, %{error: :not_connected}}

        pid ->
          info = GenServer.call(pid, :info)
          {tools, resources, prompts} = GenServer.call(pid, :catalogue)
          {id, Map.merge(info, %{tools: tools, resources: resources, prompts: prompts})}
      end
    end)
  end

  @doc "A server's tools: `[%{name:, title:, description:, inputSchema:}]`."
  def tools(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :tools))

  @doc "A server's resources: `[%{uri:, name:, description:, mimeType:}]`."
  def resources(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :resources))

  @doc "A server's resource templates: `[%{uriTemplate:, name:, description:}]`."
  def resource_templates(id),
    do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :resource_templates, 60_000))

  @doc "A server's prompts: `[%{name:, description:, arguments:}]`."
  def prompts(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :prompts, 60_000))

  @doc """
  Calls a tool. `args` is a map. Returns `{:ok, result}` or `{:error, reason}`, where
  `result` is `%{content: [...], structuredContent: ..., isError: bool, text: "..."}` and
  `text` joins the text parts.
  """
  def call(id, tool, args \\ %{}, opts \\ []) do
    with {:ok, pid} <- fetch(id) do
      GenServer.call(
        pid,
        {:call_tool, tool, args},
        Keyword.get(opts, :timeout, @limits.call_timeout)
      )
    end
  end

  @doc "Reads a resource: `{:ok, %{contents: [...], text: ...}}`."
  def read_resource(id, uri) do
    with {:ok, pid} <- fetch(id),
         do: GenServer.call(pid, {:read_resource, uri}, @limits.call_timeout)
  end

  @doc "Gets a prompt rendered by the server: `{:ok, %{description:, messages: [...]}}`."
  def get_prompt(id, name, args \\ %{}) do
    with {:ok, pid} <- fetch(id),
         do: GenServer.call(pid, {:get_prompt, name, args}, @limits.call_timeout)
  end

  @doc "Pings a server; `{:ok, %{}}` when it answers."
  def ping(id), do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, :ping))

  @doc "Answers an arbitrary MCP request, e.g. `request(\"fs\", \"resources/templates/list\")`."
  def request(id, method, params \\ %{}) do
    with {:ok, pid} <- fetch(id),
         do: GenServer.call(pid, {:request, method, params}, @limits.call_timeout)
  end

  ## Subscriptions (the calling agent's)

  @doc """
  Subscribes the calling agent (or `agent:` or `all:`) to a server's notifications: list
  changes, resource updates, logging and progress arrive as
  `{:mcp, %{server:, method:, params:}}` events. With `uri:`, also tells the server to watch
  that resource. `all: true` subscribes every agent on the node.
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
        true -> raise("no agent to subscribe (pass agent: or all: true)")
      end

    Enum.each(agents, fn agent ->
      # `agent:` may be a name or a pid; a pid is how a process subscribes itself (a test, or
      # an agent that wants delivery to a particular process).
      Store.add(subscriber_name(agent), id, uri, agent)
    end)

    :ok
  end

  defp subscriber_name(name) when is_binary(name), do: name
  defp subscriber_name(pid) when is_pid(pid), do: inspect(pid)

  @doc "Unsubscribes the calling agent (`agent:`, as in `subscribe/2`). Returns `:ok`."
  def unsubscribe(id, opts \\ []) do
    id = to_string(id)
    agent = to_string(Keyword.get(opts, :agent) || Nano.Util.calling_agent() || "unknown")
    uri = Keyword.get(opts, :uri)

    if uri,
      do: with({:ok, pid} <- fetch(id), do: GenServer.call(pid, {:unsubscribe_resource, uri}))

    Store.remove(agent, id, uri)
    :ok
  end

  @doc "The subscriptions of `agent` (default: the calling agent): `[%{agent:, server:, uri:}]`."
  def subscriptions(agent \\ nil), do: Store.list(agent || Nano.Util.calling_agent())

  @doc """
  Re-establishes an agent's subscriptions after a restart. Safe to call any time; returns how
  many resource watches were re-sent to servers.
  """
  def restore(agent) do
    for sub <- Store.list(agent), sub["uri"] && whereis(sub["server"]) != nil do
      with(
        {:ok, pid} <- fetch(sub["server"]),
        do: GenServer.call(pid, {:subscribe_resource, sub["uri"]})
      )
    end
    |> Enum.count()
  end

  @doc """
  Delivers `message` to every agent subscribed to `server` (optionally filtered by `uri`).
  Used by the server process; `message` is the `{:mcp, %{...}}` term agents receive.
  """
  def deliver(server, uri, message) do
    for sub <- Store.list(nil),
        sub["server"] == server,
        uri == nil or sub["uri"] in [nil, uri] do
      case subscriber_pid(sub) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end

    :ok
  end

  # A subscription's target: the recorded pid (for a process that subscribed itself), else
  # the live agent of that name.
  defp subscriber_pid(sub) do
    with pid_string when is_binary(pid_string) <- sub["pid"],
         [_, a, b] <- Regex.run(~r/^#PID<0\.(\d+)\.(\d+)>$/, pid_string),
         pid <- :c.pid(0, String.to_integer(a), String.to_integer(b)),
         true <- Process.alive?(pid) do
      pid
    else
      _ -> NanoAgent.whereis(sub["agent"])
    end
  end
end
