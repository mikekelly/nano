defmodule Nano.Web.Cache do
  @moduledoc """
  The web module's memory: a bounded, one-hour cache of fetched bodies (keyed by URL) and a store
  of texts a caller can page through by `handle`. Both live in one GenServer so `Nano.Web` stays
  plain functions, and both are bounded (`Nano.Web.limits/0`), so a browsing agent cannot grow the
  node without limit.

  A handle is a short id (`"w3f2a1"`), returned in every `Nano.Web.fetch_content/2` and
  `web_search/2` result, and read back with `Nano.Web.get_search_content/2`.
  """

  use GenServer

  @name __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: @name)

  @doc "The cached body for `url`, or nil."
  def get(url) do
    case Map.get(state(), {:url, url}) do
      nil -> nil
      %{at: at} = entry -> if fresh?(at), do: entry, else: nil
    end
  end

  @doc "Caches `body` under `url`, evicting the oldest entries past the bound."
  def put(url, body, meta), do: GenServer.cast(@name, {:put_url, url, body, meta})

  @doc "Stores `text` under a fresh handle for `label`; returns the handle."
  def store(label, text), do: GenServer.call(@name, {:store, to_string(label), text})

  @doc "The text stored under `handle`, or nil."
  def get_stored(handle) do
    Map.get(state(), {:text, handle})
  end

  @doc "How many URLs and texts are held."
  def size do
    s = state()
    %{urls: Enum.count(s, fn {k, _} -> match?({:url, _}, k) end), texts: Enum.count(s, fn {k, _} -> match?({:text, _}, k) end)}
  end

  @doc "Empties the cache."
  def clear, do: GenServer.call(@name, :clear)

  defp state, do: GenServer.call(@name, :state)

  defp fresh?(at) do
    System.system_time(:millisecond) - at < Application.get_env(:nano, :web_cache_ttl, 3_600_000)
  end

  ## GenServer

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call(:state, _from, s), do: {:reply, s, s}
  def handle_call(:clear, _from, _s), do: {:reply, :ok, %{}}

  def handle_call({:store, label, text}, _from, s) do
    handle = "w" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    {:reply, handle, trim(Map.put(s, {:text, handle}, %{label: label, text: text, at: System.system_time(:millisecond)}))}
  end

  @impl true
  def handle_cast({:put_url, url, body, meta}, s) do
    {:noreply, trim(Map.put(s, {:url, url}, Map.merge(meta, %{body: body})))}
  end

  def handle_cast(_msg, s), do: {:noreply, s}

  # Bounded: keep the most recent `cache_max` urls and `text_max` texts.
  defp trim(s) do
    max = Application.get_env(:nano, :web_cache_max, 40)
    texts = Application.get_env(:nano, :web_text_max, 60)

    urls = for {{:url, _} = k, v} <- s, do: {v.at, k}
    texts_kept = for {{:text, _} = k, v} <- s, do: {v.at, k}

    drop_urls = urls |> Enum.sort() |> Enum.drop(-max) |> Enum.map(&elem(&1, 1))
    drop_texts = texts_kept |> Enum.sort() |> Enum.drop(-texts) |> Enum.map(&elem(&1, 1))

    Enum.reduce(drop_urls ++ drop_texts, s, &Map.delete(&2, &1))
  end

end
