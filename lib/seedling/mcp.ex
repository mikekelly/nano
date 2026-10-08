defmodule Seedling.MCP do
  @moduledoc """
  Supervised MCP clients usable from `eval`; no harness changes or model tools.

  Implements the official **2026-07-28** revision (checked 2026-10-08): per-request
  metadata, `server/discover`, stdio and Streamable HTTP JSON/SSE, and
  `subscriptions/listen`. Automatically probes/falls back to initialization-based
  **2025-11-25**, **2025-06-18**, **2025-03-26**, or **2024-11-05** semantics
  (stdio, or Streamable HTTP; the obsolete separate HTTP+SSE endpoint is NOT supported).

      {:ok, c} = Seedling.MCP.connect("filesystem")
      Seedling.MCP.tools(c)
      Seedling.MCP.call_tool(c, "read_file", %{"path" => "/tmp/example.txt"})
      Seedling.MCP.resources(c, cursor: nil)
      Seedling.MCP.read_resource(c, "file:///tmp/example.txt")
      Seedling.MCP.prompts(c)
      Seedling.MCP.get_prompt(c, "review", %{"code" => "..."})
      Seedling.MCP.watch(c, {:agent, "alice"})
      Seedling.MCP.subscribe(c, "file:///tmp/example.txt", {:agent, "alice"})
      Seedling.MCP.status(c)
      Seedling.MCP.disconnect(c)

  Config is a JSON `servers` map in `/app/priv/seedling/mcp.json`; `servers/1`
  lists names without exposing secrets. `connect/2` accepts `:config_path`,
  `:state_dir` (default `/data/seedling/mcp`), and `:timeout` (default 15 seconds).
  See the checked-in example (filesystem requires Node+npx; HTTP URL is a placeholder).
  Examples do not launch until explicitly connected. Config is trusted code: launching commands and
  invoking tools may access/delete files or send data elsewhere. There is no
  sandbox or implicit authorization. HTTP uses TLS verification, no redirects
  or automatic retries; authentication is explicit headers (including `${ENV}`
  expansion). OAuth and interactive sampling/roots/elicitation are not advertised.
  Modern MRTR/input-required results are returned to the caller, not auto-executed;
  `request/4` can carry explicit `inputResponses` when the caller supplies them.

  Calls return `{:ok, envelope}` or `{:error, %{reason: ..., message: ...}}`.
  Request options include `timeout`, `max_bytes`, `max_items`, `progress: true`,
  `log_level: "info"`, and `notify: {:agent, "alice"}` for request-scoped events
  (default: caller pid). `watch/2` receives independent changes/log notifications.
  Envelopes contain `data` (nil if oversized), bounded JSON `text`, `truncated`,

  `output_path`, `next_offset`, and server `next_cursor`. Default limits are
  12 KB and 50 items; server discovery is one cursor page, NEVER an unbounded
  automatic walk. Cuts spill the complete JSON; `page/2` reads byte pages
  (`offset: 0` based). Text/base64 binary content is preserved, never decoded
  into the conversation. `isError` tool results remain successful RPC results.

  Events are `{:seedling_mcp, server_name, kind, bounded_envelope}`. `kind` is
  `:connected`, `:disconnected`, `:restored`, `:subscription_closed`,
  `:delivery_overflow`, or the wire notification method string (progress, logs,
  changes, acknowledgments). Eval calls and delivered messages already appear in
  the agent's dashboard timeline. Use `{:agent, name}` rather than pid for restart
  safety: intents persist atomically and delivery resolves the current pid at
  send time. While absent, up to 100 events/target are queued with explicit overflow.
  Connections retry with bounded backoff, fail in-flight calls promptly, never
  replay side-effecting tool calls, and restore subscriptions automatically.
  Status `info` and `subscriptions` also use bounded envelopes.
  `ensure_started/0` reloads default-directory persisted connections after a BEAM restart; it is
  lazy (call once at startup); custom state directories restore on connect/2. Name targets survive agent and connection restarts;
  persisted config/intents survive BEAM restart, queued events do not.

  Unsupported notifications are still forwarded for legacy servers. Modern stdio
  subscription notifications are correlated by subscription ID and discarded if
  stale. Reconnecting can miss changes; there is no exactly-once guarantee. Legacy
  unsolicited HTTP GET supports Last-Event-ID; in-flight RPC streams are not resumed.
  Modern streams are not resumable by protocol.
  `:max_message_bytes` in config caps wire messages at 8 MB by default; oversize
  frames disconnect visibly, instead of silently consuming arbitrary memory.
  Config changes take effect on disconnect/reconnect.
  Stderr is spooled separately and available via `stderr/2`; log retention is the
  caller's responsibility. Linux `setsid`/`kill` isolate and clean up process groups.

  The scripted suite requires Python 3 (no paid provider calls). The real reference
  test is opt-in: set `MCP_REFERENCE_NODE` to the Node executable and
  `MCP_REFERENCE_SERVER` to the official filesystem server's `dist/index.js`, then
  `MIX_ENV=test mix test test/seedling/mcp_reference_test.exs`. Verified with Node
  22.16.0 and `@modelcontextprotocol/server-filesystem` 2026.8.31 (SDK negotiates
  2025-11-25). Protocol source: https://modelcontextprotocol.io/specification/2026-07-28

  """
  alias Seedling.MCP.{Manager, Bounds, Config}

  def ensure_started, do: Seedling.MCP.Supervisor.ensure_started()
  def servers(path \\ Config.default_path()), do: Config.names(path)

  def connect(name, opts \\ []) do
    with {:ok, _} <- ensure_started(),
         {:ok, handle} <- GenServer.call(Manager, {:connect, name, opts}, 30_000) do
      wait_ready(
        handle,
        System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 15_000)
      )
    end
  end

  defp wait_ready(handle, deadline) do
    case status(handle) do
      {:ok, %{status: :ready}} ->
        {:ok, handle}

      {:ok, %{status: :failed, last_error: error}} ->
        {:error, error}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          error(
            :connect_timeout,
            "Server not ready; inspect status/1. Reconnection continues; disconnect/1 to stop."
          )
        else
          Process.sleep(20)
          wait_ready(handle, deadline)
        end
    end
  end

  def status(c), do: call(c, :status)

  def disconnect(c) do
    with {:ok, _} <- ensure_started(), do: GenServer.call(Manager, {:disconnect, c})
  end

  def watch(c, target), do: call(c, {:intent, :watch, nil, target})
  def unwatch(c, target), do: call(c, {:intent, :unwatch, nil, target})
  def subscribe(c, uri, target), do: call(c, {:intent, :subscribe, uri, target})
  def unsubscribe(c, uri, target), do: call(c, {:intent, :unsubscribe, uri, target})

  def tools(c, opts \\ []), do: list(c, "tools/list", opts)
  def resources(c, opts \\ []), do: list(c, "resources/list", opts)
  def resource_templates(c, opts \\ []), do: list(c, "resources/templates/list", opts)
  def prompts(c, opts \\ []), do: list(c, "prompts/list", opts)

  defp list(c, method, opts) do
    params = if opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}
    request(c, method, params, opts)
  end

  def call_tool(c, name, arguments \\ %{}, opts \\ []),
    do: request(c, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  def read_resource(c, uri, opts \\ []), do: request(c, "resources/read", %{"uri" => uri}, opts)

  def get_prompt(c, name, arguments \\ %{}, opts \\ []),
    do: request(c, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)

  def request(c, method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    if is_binary(method) and Regex.match?(~r/^[A-Za-z0-9_.\/-]+$/, method) and is_map(params) and
         json?(params) and is_integer(timeout) and timeout > 0 and
         Bounds.valid?(opts) and target?(opts[:notify]) do
      call(c, {:request, method, params, opts}, timeout + 1000)
    else
      error(
        :invalid_options,
        "Pass method string, params map, positive timeout/max_bytes/max_items."
      )
    end
  end

  defp target?(nil), do: true
  defp target?(pid) when is_pid(pid), do: true
  defp target?({:agent, name}), do: is_binary(name) and name != ""
  defp target?(_), do: false

  defp json?(params) do
    is_map(params["_meta"] || %{}) and match?({:ok, _}, Jason.encode(params))
  rescue
    _ -> false
  end

  def page(path, opts \\ []), do: Bounds.page(path, opts)

  def stderr(c, opts \\ []) do
    with {:ok, %{stderr_path: path}} when is_binary(path) <- status(c),
         do: Seedling.Shell.tail(path, opts)
  end

  defp call(c, message, timeout \\ 5000)

  defp call(%{key: key}, message, timeout) do
    with {:ok, _} <- ensure_started(),
         {:ok, pid} <- GenServer.call(Manager, {:lookup, key}) do
      GenServer.call(pid, message, timeout)
    end
  catch
    :exit, reason ->
      error(
        :connection_unavailable,
        "Connection unavailable (#{inspect(reason)}); inspect status/1 or reconnect."
      )
  end

  defp call(_, _, _), do: error(:invalid_connection, "Pass the handle returned by connect/2.")
  @doc false
  def error(reason, message), do: {:error, %{reason: reason, message: message}}
end
