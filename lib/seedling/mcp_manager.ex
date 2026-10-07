defmodule Seedling.MCP.Manager do
  use GenServer
  alias Seedling.MCP.Connection
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def call(message) do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          error -> throw(error)
        end

      _ ->
        :ok
    end

    GenServer.call(__MODULE__, message, 15000)
  end

  def init(opts) do
    Process.flag(:trap_exit, true)

    path =
      Keyword.get(
        opts,
        :path,
        Application.get_env(
          :nano,
          :mcp_state_path,
          Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "seedling_mcp.json")
        )
      )

    saved = with {:ok, b} <- File.read(path), {:ok, m} <- Jason.decode(b), do: m
    entries = if is_map(saved), do: saved, else: %{}
    state = %{path: path, entries: entries, pids: %{}}
    {:ok, Enum.reduce(entries, state, fn {n, e}, s -> start_connection(s, n, e) end)}
  end

  def handle_call(:servers, _, s), do: {:reply, Map.keys(s.entries), s}
  def handle_call({:connection, n}, _, s), do: {:reply, Map.fetch(s.pids, n) |> found(), s}

  def handle_call({:connect, n, config, recipient}, _, s) do
    cond do
      not valid_config?(config) ->
        {:reply, {:error, :invalid_config}, s}

      recipient != nil and not is_binary(recipient) ->
        {:reply, {:error, :recipient_must_be_agent_name}, s}

      Map.has_key?(s.entries, n) and s.entries[n]["config"] != config ->
        {:reply, {:error, :already_connected_with_different_config}, s}

      true ->
        e =
          Map.get(s.entries, n, %{"config" => config, "listeners" => [], "subscriptions" => %{}})

        e = if recipient, do: Map.update!(e, "listeners", &Enum.uniq([recipient | &1])), else: e
        s = %{s | entries: Map.put(s.entries, n, e)}
        s = if s.pids[n], do: s, else: start_connection(s, n, e)
        persist(s)
        {:reply, if(s.pids[n], do: {:ok, s.pids[n]}, else: {:error, :connection_start_failed}), s}
    end
  end

  def handle_call({:disconnect, n}, _, s) do
    if pid = s.pids[n], do: GenServer.stop(pid, :normal)
    s = %{s | entries: Map.delete(s.entries, n), pids: Map.delete(s.pids, n)}
    persist(s)
    {:reply, :ok, s}
  end

  def handle_call({op, n, recipient}, _, s) when op in [:listen, :unlisten] do
    if is_binary(recipient) and s.entries[n] do
      e =
        Map.update!(s.entries[n], "listeners", fn l ->
          if op == :listen, do: Enum.uniq([recipient | l]), else: List.delete(l, recipient)
        end)

      s = %{s | entries: Map.put(s.entries, n, e)}
      persist(s)
      {:reply, :ok, s}
    else
      {:reply, {:error, :unknown_server_or_invalid_recipient}, s}
    end
  end

  def handle_call({op, n, uri, recipient}, _, s) when op in [:subscribe, :unsubscribe] do
    if is_map(s.entries[n]) and is_binary(recipient) and is_binary(uri) do
      e = s.entries[n]
      subs = e["subscriptions"]
      names = Map.get(subs, uri, [])

      names =
        if op == :subscribe,
          do: Enum.uniq([recipient | names]),
          else: List.delete(names, recipient)

      subs = if names == [], do: Map.delete(subs, uri), else: Map.put(subs, uri, names)
      e = Map.put(e, "subscriptions", subs)
      s = %{s | entries: Map.put(s.entries, n, e)}
      persist(s)
      if pid = s.pids[n], do: Connection.subscriptions(pid, Map.keys(subs))
      {:reply, :ok, s}
    else
      {:reply, {:error, :unknown_server_or_invalid_subscription}, s}
    end
  end

  def handle_info({:mcp_ready, n}, s) do
    if e = s.entries[n], do: Connection.subscriptions(s.pids[n], Map.keys(e["subscriptions"]))
    forward(s, n, "connection/ready", %{})
    {:noreply, s}
  end

  def handle_info({:mcp_event, n, method, params}, s) do
    forward(s, n, method, params)
    {:noreply, s}
  end

  def handle_info({:EXIT, pid, reason}, s) do
    case Enum.find(s.pids, fn {_, p} -> p == pid end) do
      {n, _} ->
        forward(s, n, "connection/down", %{reason: inspect(reason)})
        Process.send_after(self(), {:restart, n}, 1000)
        {:noreply, %{s | pids: Map.delete(s.pids, n)}}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({:restart, n}, s) do
    s = if s.entries[n] && !s.pids[n], do: start_connection(s, n, s.entries[n]), else: s
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp forward(s, n, method, params) do
    if e = s.entries[n] do
      recipients =
        if method == "notifications/resources/updated",
          do: Map.get(e["subscriptions"], params["uri"], []),
          else: []

      recipients = Enum.uniq(e["listeners"] ++ recipients)
      event = {:mcp, n, method, Seedling.MCP.bounded(params)}

      Enum.each(recipients, fn name ->
        case NanoAgent.whereis(name) do
          pid when is_pid(pid) -> send(pid, event)
          _ -> :ok
        end
      end)
    end
  end

  defp start_connection(s, n, e) do
    case Connection.start_link(n, e["config"], self()) do
      {:ok, pid} ->
        %{s | pids: Map.put(s.pids, n, pid)}

      {:error, reason} ->
        forward(s, n, "connection/down", %{reason: inspect(reason)})
        Process.send_after(self(), {:restart, n}, 1000)
        s
    end
  end

  def terminate(_, s) do
    Enum.each(s.pids, fn {_, pid} ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    :ok
  end

  defp persist(s) do
    File.mkdir_p!(Path.dirname(s.path))
    tmp = s.path <> ".tmp"
    File.write!(tmp, Jason.encode!(s.entries))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, s.path)
  end

  defp valid_config?(%{"command" => c} = m), do: is_binary(c) and is_list(Map.get(m, "args", []))
  defp valid_config?(%{"url" => u}), do: is_binary(u) and URI.parse(u).scheme in ["http", "https"]
  defp valid_config?(_), do: false
  defp found({:ok, p}), do: {:ok, p}
  defp found(:error), do: {:error, :unknown_server}
end
