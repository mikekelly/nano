defmodule Seedling.MCP do
  @moduledoc "MCP client. See seedings/MCP_USAGE.md. Named listeners/subscriptions are durable; results are bounded and spill to disk."
  alias Seedling.MCP.{Manager, Connection}
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  def start_link(opts \\ []), do: Manager.start_link(opts)

  def connect(name, config, opts \\ []) when is_binary(name) and is_map(config) do
    with {:ok, pid} <- Manager.call({:connect, name, config, Keyword.get(opts, :notify)}),
         do: Connection.await(pid, Keyword.get(opts, :timeout, 15000))
  end

  def load(path \\ "/app/priv/seedling_mcp.json", opts \\ []) do
    with {:ok, text} <- File.read(path), {:ok, config} <- Jason.decode(text) do
      servers = Map.get(config, "mcpServers", config)

      if is_map(servers),
        do: Enum.map(servers, fn {n, c} -> {n, connect(n, c, opts)} end),
        else: {:error, :invalid_config}
    end
  end

  def disconnect(name), do: Manager.call({:disconnect, name})
  def servers, do: Manager.call(:servers)
  def listen(name, recipient), do: Manager.call({:listen, name, recipient})
  def unlisten(name, recipient), do: Manager.call({:unlisten, name, recipient})

  def subscribe(name, uri, recipient) when is_binary(uri) and is_binary(recipient),
    do: Manager.call({:subscribe, name, uri, recipient})

  def unsubscribe(name, uri, recipient), do: Manager.call({:unsubscribe, name, uri, recipient})
  def info(name), do: request(name, "__info", %{})
  def tools(name, opts \\ []), do: list(name, "tools/list", opts)
  def resources(name, opts \\ []), do: list(name, "resources/list", opts)
  def resource_templates(name, opts \\ []), do: list(name, "resources/templates/list", opts)
  def prompts(name, opts \\ []), do: list(name, "prompts/list", opts)

  def call_tool(name, tool, args \\ %{}, opts \\ []),
    do: request(name, "tools/call", %{"name" => tool, "arguments" => args}, opts)

  def read_resource(name, uri, opts \\ []),
    do: request(name, "resources/read", %{"uri" => uri}, opts)

  def get_prompt(name, prompt, args \\ %{}, opts \\ []),
    do: request(name, "prompts/get", %{"name" => prompt, "arguments" => args}, opts)

  def request(name, method, params \\ %{}, opts \\ []) do
    with {:ok, pid} <- Manager.call({:connection, name}),
         result <- Connection.request(pid, method, params, Keyword.get(opts, :timeout, 30000)) do
      case result do
        {:ok, data} -> {:ok, bounded(data, opts)}
        other -> other
      end
    end
  catch
    :exit, reason -> {:error, {:connection_exit, reason}}
  end

  defp list(name, method, opts) do
    params = if opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}
    request(name, method, params, opts)
  end

  def bounded(data, opts \\ []) do
    bytes = Jason.encode!(data)
    cap = Keyword.get(opts, :max_bytes, 24000) |> max(256) |> min(48000)

    if byte_size(bytes) <= cap do
      data
    else
      dir = Application.get_env(:nano, :mcp_result_dir, "/data/seedling/mcp/results")
      File.mkdir_p!(dir)

      path =
        Path.join(
          dir,
          "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
        )

      File.write!(path, bytes)

      %{
        truncated: true,
        bytes: byte_size(bytes),
        path: path,
        preview: String.slice(bytes, 0, div(cap, 4))
      }
    end
  end
end
