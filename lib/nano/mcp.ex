defmodule Nano.MCP do
  @moduledoc """
  MCP client (protocol 2025-11-25). See `docs/nova-mcp.md` for configuration.

      {:ok, server} = Nano.MCP.connect("files")
      Nano.MCP.tools(server)
      Nano.MCP.call_tool(server, "read_file", %{"path" => "/tmp/example"})
      Nano.MCP.subscribe(server, "file:///tmp/example", "my-agent")

  Events are `{:mcp, server_name, method, params}`. Stable agent names survive
  process restarts; PID subscribers do not. Results exceeding the byte budget
  are spilled to disk, never silently truncated. Connections are supervised.
  """
  @config "/app/config/mcp.json"
  def child_spec(opts), do: Nano.MCP.Supervisor.child_spec(opts)

  def start_link(opts \\ []), do: Nano.MCP.Supervisor.start_link(opts)

  def load_config(path \\ @config) do
    with {:ok, bytes} <- File.read(path), {:ok, config} <- Jason.decode(bytes) do
      case config do
        %{"mcpServers" => servers} when is_map(servers) ->
          if Enum.all?(servers, fn {name, config} ->
               valid_string?(name) and validate_config(config) == :ok
             end), do: {:ok, servers}, else: {:error, :invalid_server_config}

        _ ->
          {:error, :invalid_config}
      end
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      error -> error
    end
  end

  def connect(name, opts \\ []) do
    with :ok <- connect_options(name, opts),
         {:ok, config} <- config(name, opts),
         :ok <- validate_config(config),
         :ok <- ensure_started() do
      spec = {Nano.MCP.Connection, {name, config, opts}}

      case DynamicSupervisor.start_child(Nano.MCP.Connections, spec) do
        {:ok, pid} -> connect_ready(pid, opts)
        {:error, {:already_started, pid}} -> connect_ready(pid, opts)
        error -> error
      end
    end
  end

  @doc "Validate a server descriptor without starting a process or exposing its values."
  def validate_config(config) when is_map(config) do
    cond do
      Map.has_key?(config, "command") and not Map.has_key?(config, "url") ->
        if valid_string?(config["command"]) and string_list?(Map.get(config, "args", [])) and
             env_map?(Map.get(config, "env", %{})) and
             (config["cwd"] == nil or valid_string?(config["cwd"])) and
             Map.get(config, "transport", "stdio") == "stdio",
           do: :ok,
           else: {:error, :invalid_stdio_config}

      Map.has_key?(config, "url") and not Map.has_key?(config, "command") ->
        url = config["url"]

        valid_url =
          if valid_string?(url) do
            case URI.parse(url) do
              %URI{scheme: scheme, host: host}
              when scheme in ["http", "https"] and is_binary(host) ->
                host != ""

              _ ->
                false
            end
          else
            false
          end

        if valid_url and header_map?(Map.get(config, "headers", %{})) and
             positive?(Map.get(config, "receive_timeout", 60_000)) and
             Map.get(config, "transport", "http") in ["http", "streamable_http"],
           do: :ok,
           else: {:error, :invalid_http_config}

      true ->
        {:error, :invalid_server_config}
    end
  rescue
    _ -> {:error, :invalid_server_config}
  end

  def validate_config(_), do: {:error, :invalid_server_config}
  defp string_list?(list), do: is_list(list) and Enum.all?(list, &string_value?/1)

  defp string_map?(map),
    do: is_map(map) and Enum.all?(map, fn {k, v} -> valid_string?(k) and string_value?(v) end)

  defp env_map?(map) do
    string_map?(map) and Enum.all?(map, fn {key, _} -> not String.contains?(key, "=") end)
  end

  defp header_map?(map) do
    string_map?(map) and
      Enum.all?(map, fn {key, value} ->
        Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, key) and
          not String.contains?(value, ["\r", "\n"])
      end)
  end

  defp string_value?(s), do: is_binary(s) and String.valid?(s) and not String.contains?(s, <<0>>)
  defp valid_string?(s), do: string_value?(s) and byte_size(s) > 0
  defp positive?(n), do: is_integer(n) and n > 0

  defp connect_options(name, opts) do
    if valid_string?(name) and is_list(opts) and Keyword.keyword?(opts) and
         positive?(Keyword.get(opts, :timeout, 15_000)) and
         valid_string?(Keyword.get(opts, :state_dir, "/data/mcp")) and
         valid_string?(Keyword.get(opts, :config_path, @config)) and
         (Keyword.get(opts, :recipient, :caller) in [:caller, false] or
            is_pid(opts[:recipient]) or valid_string?(opts[:recipient])) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp connect_ready(pid, opts) do
    safe_call(
      pid,
      {:ready, Keyword.get(opts, :recipient, :caller)},
      Keyword.get(opts, :timeout, 15_000)
    )
  end

  defp config(name, opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} when is_map(config) ->
        {:ok, config}

      {:ok, _} ->
        {:error, :invalid_server_config}

      :error ->
        with {:ok, servers} <- load_config(Keyword.get(opts, :config_path, @config)) do
          case Map.fetch(servers, name) do
            {:ok, config} -> {:ok, config}
            :error -> {:error, :unknown_server}
          end
        end
    end
  end

  defp ensure_started do
    case Process.whereis(Nano.MCP.Supervisor) do
      nil ->
        case Supervisor.start_child(Nano.Supervisor, {Nano.MCP.Supervisor, []}) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, :already_present} -> :ok
          error -> error
        end

      _ ->
        :ok
    end
  end

  def ready(server, timeout \\ 15_000), do: safe_call(server, :ready, timeout)
  def status(server), do: safe_call(server, :status, 5_000)

  def disconnect(server) do
    case GenServer.whereis(resolve(server)) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(Nano.MCP.Connections, pid)
      _ -> {:error, :not_found}
    end
  end

  def watch(server, recipient \\ self()) do
    if is_pid(recipient) or valid_string?(recipient),
      do: safe_call(server, {:watch, recipient}, 5_000),
      else: {:error, :invalid_recipient}
  end

  def request(server, method, params \\ %{}, opts \\ []) do
    with :ok <- request_options(method, params, opts) do
      do_request(server, method, params, opts)
    end
  end

  defp do_request(server, method, params, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    meta = Keyword.get(opts, :meta, %{})

    meta =
      if opts[:progress_token],
        do: Map.put(meta, "progressToken", opts[:progress_token]),
        else: meta

    params = if map_size(meta) > 0, do: Map.put(params, "_meta", meta), else: params

    with {:ok, result} <- safe_call(server, {:request, method, params, timeout}, timeout + 1_000) do
      Nano.MCP.Result.bound(result, opts)
    end
  end

  defp request_options(method, params, opts) do
    if valid_string?(method) and is_map(params) and is_list(opts) and Keyword.keyword?(opts) and
         positive?(Keyword.get(opts, :timeout, 30_000)) and
         positive?(Keyword.get(opts, :max_bytes, 16_384)) and
         valid_string?(Keyword.get(opts, :spill_dir, System.tmp_dir!())) and
         is_map(Keyword.get(opts, :meta, %{})) and
         (opts[:progress_token] == nil or is_binary(opts[:progress_token]) or
            is_integer(opts[:progress_token])) do
      case Jason.encode({params, opts[:meta]} |> Tuple.to_list()) do
        {:ok, _} -> :ok
        _ -> {:error, :invalid_request}
      end
    else
      {:error, :invalid_options}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def tools(server, opts \\ []), do: listing(server, "tools/list", opts)
  def resources(server, opts \\ []), do: listing(server, "resources/list", opts)

  def resource_templates(server, opts \\ []),
    do: listing(server, "resources/templates/list", opts)

  def prompts(server, opts \\ []), do: listing(server, "prompts/list", opts)

  defp listing(server, method, opts) do
    with :ok <- request_options(method, %{}, opts) do
      params = if opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}
      request(server, method, params, opts)
    end
  end

  def call_tool(server, name, arguments \\ %{}, opts \\ []),
    do: request(server, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  def read_resource(server, uri, opts \\ []),
    do: request(server, "resources/read", %{"uri" => uri}, opts)

  def get_prompt(server, name, arguments \\ %{}, opts \\ []),
    do: request(server, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)

  def subscribe(server, uri, recipient \\ self()),
    do: subscription(server, :subscribe, uri, recipient)

  def unsubscribe(server, uri, recipient \\ self()),
    do: subscription(server, :unsubscribe, uri, recipient)

  defp subscription(server, operation, uri, recipient) do
    if valid_string?(uri) and (is_pid(recipient) or valid_string?(recipient)),
      do: safe_call(server, {operation, uri, recipient}, 31_000),
      else: {:error, :invalid_subscription}
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name), do: {:via, Registry, {Nano.MCP.Registry, name}}

  defp safe_call(server, message, timeout) do
    GenServer.call(resolve(server), message, timeout)
  catch
    :exit, reason -> {:error, {:connection, reason}}
  end
end

defmodule Nano.MCP.Supervisor do
  @moduledoc false
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Nano.MCP.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Nano.MCP.Connections},
        {Nano.MCP.Bootstrap, opts}
      ],
      strategy: :one_for_all
    )
  end
end

defmodule Nano.MCP.Bootstrap do
  @moduledoc false
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def init(opts), do: {:ok, opts, {:continue, :load}}
  @impl true
  def handle_continue(:load, opts) do
    path = Keyword.get(opts, :config_path, "/app/config/mcp.json")

    case Nano.MCP.load_config(path) do
      {:ok, servers} ->
        Enum.each(servers, fn {name, config} ->
          DynamicSupervisor.start_child(
            Nano.MCP.Connections,
            {Nano.MCP.Connection, {name, config, opts}}
          )
        end)

      _ ->
        :ok
    end

    {:noreply, opts}
  end
end
