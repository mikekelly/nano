defmodule SeedMCP do
  @moduledoc """
  Bounded MCP client for stdio and Streamable HTTP, revision 2026-07-28.

  Defaults to current stateless requests with per-request metadata and
  `server/discover`. For legacy servers set config `protocolVersion` or option
  `protocol:` to `2025-11-25`; this enables initialization, sessions and GET SSE.
  No sampling, elicitation or roots are advertised. Modern multi-round-trip
  input requests are returned to the caller unchanged, not automatically handled.

      {:ok, client} = SeedMCP.connect("filesystem", owner: "my-agent")
      {:ok, _} = SeedMCP.await_ready(client)
      SeedMCP.tools(client)
      SeedMCP.call_tool(client, "read_file", %{"path" => "/tmp/example"})
      SeedMCP.subscribe(client, "file:///tmp/example")

  Config defaults to `lib/seed_mcp/servers.json` under the application checkout:
  `{"mcpServers":{"filesystem":{"command":"/usr/bin/server","args":[]}}}`.
  HTTP entries use `url` and optional `headers` (never emitted in events).
  Use `config:` to override. Commands are executables, not shell strings.

  `owner:` is a PID or Nano agent name. Named owners are resolved for every event,
  so agent restarts need no rebinding. Events are maps tagged `mcp: server_name`:
  connected/disconnected, request, response and notification. Results larger than
  `result_bytes` (default 12000) are JSON spill descriptors; `page/2` reads bytes.
  Protocol frames cap at `frame_bytes` (default 2MB); oversized frames disconnect.

  Subscriptions are saved under `state_dir` (default `/data/seed_mcp`) keyed by
  owner name and server. On reconnect/restart they are reissued. PID owners are
  ephemeral: supply `subscription_key:` to persist them. `connect` supervises
  clients under SeedMCP.Supervisor; use `start_for` to save runtime config for
  node restoration. Clients automatically reconnect after transport failures.
  Notifications when the owner is absent are not durably queued.

  Delegation: `SeedMCP.start_for(child_name, specs)` returns stable handles only
  after discovery/initialization; call `SeedMCP.handles(child_name)` in a child
  and `SeedMCP.restore(child_name)` after node restart. See SeedMCP.Runtime.

  Calls return `{:ok, result}` or `{:error, bounded_detail}`. List functions accept
  a cursor and deliberately return one server page, not unbounded aggregation.
  HTTP supports JSON and incremental SSE POST replies. Current resource
  subscriptions use long-lived `subscriptions/listen` and await acknowledgment;
  legacy mode uses a GET notification stream (405 disables GET). Stream closure
  and session expiry reconnect and resubscribe. Automatic version fallback is
  deliberately not performed: choose a supported revision in config.
  Use `request/4` for other protocol methods (including subscription filters).
  Only resource subscriptions made through `subscribe/2` are persisted.
  Cancel those with `unsubscribe/2` (not `cancel_subscription/2`) to remove the
  durable intent. Call `tools/2` and page through discovery before HTTP tool
  calls to cache schemas for `x-mcp-header` parameter mirroring.
  Keep one client per owner/server persistence key to avoid concurrent updates.
  Spill files are retained for caller cleanup; no secrets are intentionally logged,
  but server results may contain sensitive data. Protect `state_dir` accordingly.

  Interoperability smoke (2026-10-08): public https://mcp.deepwiki.com/mcp
  successfully initialized at 2025-11-25, listed tools and ran read_wiki_structure
  for modelcontextprotocol/python-sdk without credentials. Official Python SDK
  mcp 2.3.0 over stdio successfully discovered 2026-07-28, listed/called a tool,
  read a resource and acknowledged a resource subscription. These are smoke
  checks, not exhaustive conformance certification; deterministic tests use fakes.
  """
  def connect(server, opts \\ [])
  def connect(server, opts) when is_map(server), do: SeedMCP.Runtime.connect(server, opts)

  def connect(name, opts) when is_binary(name) do
    config = Keyword.get(opts, :config, Path.join(__DIR__, "seed_mcp/servers.json"))

    with {:ok, bytes} <- File.read(config),
         {:ok, doc} <- Jason.decode(bytes),
         server when is_map(server) <- get_in(doc, ["mcpServers", name]) do
      SeedMCP.Runtime.connect(Map.put(server, "name", name), opts)
    else
      nil -> {:error, "Unknown MCP server #{name}; add it to #{config}"}
      error -> {:error, inspect(error, limit: 5, printable_limit: 500)}
    end
  end

  @doc "Starts and awaits configured clients for an agent, saving runtime specs for node restart. See SeedMCP.Runtime."
  def start_for(owner, servers, opts \\ []), do: SeedMCP.Runtime.start_for(owner, servers, opts)
  @doc "Restarts clients from this agent's saved runtime configuration."
  def restore(owner, opts \\ []), do: SeedMCP.Runtime.restore(owner, opts)
  @doc "Returns a map of server names to stable via handles for the named agent."
  def handles(owner), do: SeedMCP.Runtime.handles(owner)
  @doc "Waits inside code, not model turns, for discovery/initialization to complete."
  def await_ready(client, timeout \\ 30_000), do: SeedMCP.Runtime.await_ready(client, timeout)

  def start_link(opts), do: SeedMCP.Client.start_link(opts)

  def child_spec(opts),
    do: %{id: {__MODULE__, opts[:server_name]}, start: {__MODULE__, :start_link, [opts]}}

  def request(client, method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with true <- is_integer(timeout) and timeout > 0 and is_binary(method) and is_map(params),
         {:ok, _} <- Jason.encode(params) do
      GenServer.call(client, {:request, method, params, timeout}, timeout + 1000)
    else
      _ -> {:error, "Expected binary method, JSON-encodable map params and positive timeout"}
    end
  catch
    :exit, reason -> {:error, inspect(reason, limit: 5, printable_limit: 500)}
  end

  def tools(c, cursor \\ nil), do: request(c, "tools/list", cursor(cursor))
  def resources(c, cursor \\ nil), do: request(c, "resources/list", cursor(cursor))

  def resource_templates(c, cursor \\ nil),
    do: request(c, "resources/templates/list", cursor(cursor))

  def prompts(c, cursor \\ nil), do: request(c, "prompts/list", cursor(cursor))

  def get_prompt(c, name, arguments \\ %{}),
    do: request(c, "prompts/get", %{"name" => name, "arguments" => arguments})

  def call_tool(c, name, arguments \\ %{}, opts \\ []),
    do: request(c, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  def read_resource(c, uri), do: request(c, "resources/read", %{"uri" => uri})
  def subscribe(c, uri), do: request(c, "resources/subscribe", %{"uri" => uri})
  def unsubscribe(c, uri), do: request(c, "resources/unsubscribe", %{"uri" => uri})

  @doc "Opens a current-revision notification filter; acknowledgment includes the subscription ID. Only resource subscribe/2 filters persist."
  def listen(c, notifications),
    do: request(c, "subscriptions/listen", %{"notifications" => notifications})

  @doc "Cancels a subscriptions/listen request by the ID in its acknowledgment metadata."
  def cancel_subscription(c, id), do: GenServer.call(c, {:cancel_subscription, id})
  def status(c), do: GenServer.call(c, :status)
  def owner(c, owner), do: GenServer.call(c, {:owner, owner})

  def stop(c) do
    pid = GenServer.whereis(c)

    if Process.whereis(SeedMCP.Supervisor) && is_pid(pid) do
      case DynamicSupervisor.terminate_child(SeedMCP.Supervisor, pid) do
        :ok -> :ok
        {:error, :not_found} -> GenServer.stop(c)
      end
    else
      GenServer.stop(c)
    end
  end

  def page(path, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = min(Keyword.get(opts, :limit, 12_000), 50_000)

    with true <- is_integer(offset) and offset >= 0 and is_integer(limit) and limit > 0,
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary]) do
      result = :file.pread(file, offset, limit)
      :file.close(file)

      case result do
        {:ok, bytes} -> {:ok, %{data: bytes, next_offset: offset + byte_size(bytes)}}
        :eof -> {:ok, %{data: "", next_offset: nil}}
        error -> error
      end
    else
      false -> {:error, :invalid_page}
      error -> error
    end
  end

  defp cursor(nil), do: %{}
  defp cursor(value), do: %{"cursor" => value}
end
