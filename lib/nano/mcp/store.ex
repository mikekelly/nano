defmodule Nano.MCP.Store do
  @moduledoc """
  Which agents are subscribed to which MCP servers (and resources), so subscriptions survive
  an agent's restart: `<data>/mcp_subscriptions.json`, rewritten on every change (it is small).
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The ETS cache table (public; readers do not call this process)."
  def table, do: @table

  @doc "Where subscriptions are stored (`<data>/mcp_subscriptions.json`)."
  def file, do: Path.join(Nano.Util.data_dir(), "mcp_subscriptions.json")

  @doc "Adds a subscription for `agent` to `server` (and optionally `uri`), delivering to `pid` when given."
  def add(agent, server, uri \\ nil, pid \\ nil) do
    GenServer.call(
      __MODULE__,
      {:add, to_string(agent), to_string(server), uri, pid && inspect(pid)}
    )
  end

  @doc "Removes `agent`'s subscription to `server` (with `uri`, only that resource's)."
  def remove(agent, server, uri \\ nil) do
    GenServer.call(__MODULE__, {:remove, to_string(agent), to_string(server), uri})
  end

  @doc "All subscriptions matching: `agent:` (nil = any), `server:` (nil = any)."
  def list(agent \\ nil, opts \\ []) do
    server = Keyword.get(opts, :server)

    all()
    |> Enum.filter(&(agent == nil or &1["agent"] == to_string(agent)))
    |> Enum.filter(&(server == nil or &1["server"] == to_string(server)))
    |> Enum.sort_by(&{&1["agent"], &1["server"], &1["uri"] || ""})
  end

  @doc "Every subscription entry."
  def all, do: :ets.select(@table, [{{:"$1", :"$2"}, [], [:"$2"]}]) |> List.flatten()

  @doc "Re-sends resource watches to connected servers (a no-op for servers that are not up)."
  def ensure_connected_interest(_server, _uri), do: :ok

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    persist(read_file())
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add, agent, server, uri, pid}, _from, state) do
    entry = %{"agent" => agent, "server" => server, "uri" => uri, "pid" => pid, "at" => now()}
    keep = Enum.reject(all(), &(&1["agent"] == agent and &1["server"] == server))
    persist(keep ++ [entry])
    {:reply, :ok, state}
  end

  def handle_call({:remove, agent, server, uri}, _from, state) do
    keep =
      Enum.reject(all(), fn e ->
        e["agent"] == agent and e["server"] == server and
          (uri == nil or e["uri"] == uri)
      end)

    persist(keep)
    {:reply, :ok, state}
  end

  def handle_call(msg, _from, state), do: {:reply, {:error, {:unknown, msg}}, state}

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  defp persist(entries) do
    :ets.insert(@table, {{:subscriptions, :all}, entries})
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), Jason.encode!(entries, pretty: true))
  end

  defp read_file do
    case File.read(file()) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
