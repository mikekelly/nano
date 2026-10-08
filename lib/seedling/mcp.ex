defmodule Seedling.MCP do
  @moduledoc """
  Durable MCP connections and mailbox notifications for stable named agents.

  Configure `priv/seedling/mcp.json`, start `Seedling.MCP.Supervisor`, then:

      Seedling.MCP.connect("files", agent: "researcher")
      Seedling.MCP.tools("files")
      Seedling.MCP.call("files", "read_file", %{"path" => "/tmp/example"})
      Seedling.MCP.subscribe("files", "file:///tmp/example", agent: "researcher")

  Results are `{:ok, map}` / `{:error, reason}`. Large results spill, returning
  `%{truncated: true, path: ..., bytes: ..., preview: ...}`; use `result_page/2`.
  Lists fetch ONE server page; pass `cursor:` for the next page. No automatic polling.
  Events are `%{mcp: server, type: type, ...}` sent via `Nano.Names` at delivery time.
  See `docs/seedling/mcp.md` for transports, security and protocol limitations.
  """
  alias Seedling.MCP.{Manager, Result}

  def protocol_version, do: "2026-07-28"
  def servers(opts \\ []), do: safe(fn -> GenServer.call(manager(opts), :servers) end)

  def connect(name, opts) when is_binary(name) do
    with agent when is_binary(agent) and byte_size(agent) > 0 <- opts[:agent],
         {:ok, pid} <- safe(fn -> GenServer.call(manager(opts), {:connect, name, agent}) end) do
      bound_reply(safe(fn -> GenServer.call(pid, :await, timeout(opts) + 1000) end), opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :stable_agent_required}
    end
  end

  def status(name, opts \\ []),
    do: bound_reply(with_client(name, opts, &GenServer.call(&1, :status)), opts)

  def tools(name, opts \\ []), do: list(name, "tools/list", opts)
  def resources(name, opts \\ []), do: list(name, "resources/list", opts)
  def resource_templates(name, opts \\ []), do: list(name, "resources/templates/list", opts)
  def prompts(name, opts \\ []), do: list(name, "prompts/list", opts)

  def call(name, tool, arguments \\ %{}, opts \\ []),
    do: request(name, "tools/call", %{"name" => tool, "arguments" => arguments}, opts)

  def read(name, uri, opts \\ []), do: request(name, "resources/read", %{"uri" => uri}, opts)

  def get_prompt(name, prompt, arguments \\ %{}, opts \\ []),
    do: request(name, "prompts/get", %{"name" => prompt, "arguments" => arguments}, opts)

  def subscribe(name, uri, opts), do: intent(name, uri, true, opts)
  def unsubscribe(name, uri, opts), do: intent(name, uri, false, opts)

  def disconnect(name, opts),
    do: safe(fn -> GenServer.call(manager(opts), {:disconnect, name, opts[:agent]}) end)

  @doc "One bounded JSON-RPC request; does not retry side-effecting calls on disconnect."
  def request(name, method, params \\ %{}, opts \\ []) do
    with_client(name, opts, fn pid ->
      case GenServer.call(pid, {:request, method, params, timeout(opts)}, timeout(opts) + 1000) do
        {:ok, value} ->
          Result.bound(value, Keyword.get(opts, :max_bytes, 8192), spill_dir(opts))

        {:error, value} when is_map(value) ->
          case Result.bound(value, 4096, spill_dir(opts)) do
            {:ok, bounded} -> {:error, bounded}
            error -> error
          end

        error ->
          error
      end
    end)
  end

  def result_page(path, opts \\ []), do: Result.page(path, opts)
  def manager(opts), do: Manager.name(Keyword.get(opts, :instance, :default))
  defp timeout(opts), do: Keyword.get(opts, :timeout, 15_000)

  defp spill_dir(opts),
    do:
      Keyword.get(
        opts,
        :spill_dir,
        Path.join(Application.get_env(:nano, :spill_dir, "/data/spill"), "mcp")
      )

  defp list(name, method, opts) do
    params = if opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}
    request(name, method, params, opts)
  end

  defp intent(name, uri, add, opts) do
    if is_binary(opts[:agent]) and is_binary(uri) do
      safe(fn -> GenServer.call(manager(opts), {:intent, name, opts[:agent], uri, add}) end)
    else
      {:error, :stable_agent_required}
    end
  end

  defp with_client(name, opts, fun) do
    with {:ok, pid} <- safe(fn -> GenServer.call(manager(opts), {:client, name}) end),
         do: safe(fn -> fun.(pid) end)
  end

  defp bound_reply({:ok, value}, opts),
    do: Result.bound(value, opts[:max_bytes] || 8192, spill_dir(opts))

  defp bound_reply(error, _), do: error

  defp safe(fun) do
    fun.()
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:unavailable, reason}}
  end
end
