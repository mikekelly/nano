defmodule Nano.FakeOpenRouter do
  @moduledoc """
  A scripted stand-in for OpenRouter's chat completions endpoint (and its model list and OAuth
  key exchange, `keys/1`): a real HTTP server on a random localhost port, so agents exercise
  the whole `Req` path.

      Nano.FakeOpenRouter.start()           # idempotent; points the openrouter_base_url setting at the fake
      model = Nano.FakeOpenRouter.model()   # a fresh slug, listed; responses are queued per
                                            # model, so tests using different models don't interfere
      Nano.FakeOpenRouter.push(model, calls: [eval: "1 + 1"])
      Nano.FakeOpenRouter.push(model, calls: [{:eval, "x = 1"}, {:idle, 50}])  # idle: nil = no wakeup
      Nano.FakeOpenRouter.push(model, text: "done")
      Nano.FakeOpenRouter.push(model, status: 500)                      # an HTTP error
      {:ok, _pid} = NanoAgent.start([name: "alice"] ++ Nano.FakeOpenRouter.opts(model))
      NanoAgent.notify("alice", :hi)
      assert_receive {:openrouter_request, ^model, body}                # decoded JSON body

  Every request for a model is also sent as `{:openrouter_request, model, body}` to the last
  process that called `push/2` or `listen/1` for it. A request for a model with nothing
  queued waits until something is pushed, so a test can hold an agent in `:thinking`.

  Response options: `text:`, `calls:` (a list of `{:eval, code}`, `{:idle, ms | nil}`, or
  `{name, args}` with args a map, a raw JSON string, or `{:raw, term}` to send `term` as the
  arguments value itself), `usage: {prompt, completion, cached}` (default `{100, 10, 0}`),
  `cost:` (default 0.001), `provider:`, `finish_reason:`, `reasoning:`, `reasoning_details:`. Or
  `status:` (and optionally `body:` and `headers:`, a list of `{name, value}`) for an error
  response. The success shape mirrors what
  OpenRouter returned for anthropic/claude-haiku-4.5 in October 2026.
  """
  use GenServer

  @doc "Starts the fake once (unlinked, so it outlives the calling test) and points the app at it."
  def start do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    port = GenServer.call(__MODULE__, :port)
    :ok = Nano.Settings.put(:openrouter_base_url, "http://127.0.0.1:#{port}/api/v1")
  end

  @doc """
  A fresh model slug, added to the models `GET /models` lists (as `entry` there, by default
  with a 1,000,000-token window and every reasoning level), and the node's cached list dropped,
  so that agents can be started on it.
  """
  def model(entry \\ %{}) do
    slug = "fake/model-#{System.unique_integer([:positive])}"
    defaults = %{"context_length" => 1_000_000, "reasoning" => %{"supported_efforts" => []}}
    GenServer.call(__MODULE__, {:list, Map.merge(defaults, Map.put(entry, "id", slug))})
    :persistent_term.erase({Nano.OpenRouter, :models})
    slug
  end

  @doc """
  `NanoAgent.start/1` options for an agent on `model`, which has no defaults: reasoning off,
  500 turns, 30,000,000 tokens and a 1,000,000-token context, unless `overrides` say otherwise.
  """
  def opts(model, overrides \\ []) do
    Keyword.merge(
      [
        model: model,
        reasoning: "off",
        max_turns: 500,
        max_tokens: 30_000_000,
        max_context: 1_000_000
      ],
      overrides
    )
  end

  @doc "Queues one response for model; the caller receives that model's requests."
  def push(model, response),
    do: GenServer.call(__MODULE__, {:push, model, self(), build(response)})

  @doc "Makes the caller receive model's requests without queuing a response."
  def listen(model), do: GenServer.call(__MODULE__, {:listen, model, self()})

  @doc "What `GET /models` answers: a list of model maps (sent as `data`), or an HTTP status."
  def models(models_or_status), do: GenServer.call(__MODULE__, {:models, models_or_status})

  @doc """
  Queues answers (`{status, body}`) for `POST /auth/keys`, the OAuth key exchange, replacing
  any queued before; the caller then receives each exchange as `{:openrouter_keys, body}`.
  With nothing queued it answers 403.
  """
  def keys(answers), do: GenServer.call(__MODULE__, {:keys, self(), answers})

  @doc false
  def request(body), do: GenServer.call(__MODULE__, {:request, body}, :infinity)

  @impl true
  def init(nil) do
    {:ok, server} =
      Bandit.start_link(plug: __MODULE__.Endpoint, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{port: port, models: %{}, list: 500, keys: {nil, []}}}
  end

  @impl true
  def handle_call(:port, _from, s), do: {:reply, s.port, s}

  def handle_call({:keys, pid, answers}, _from, s), do: {:reply, :ok, %{s | keys: {pid, answers}}}

  def handle_call({:exchange, body}, _from, %{keys: {pid, answers}} = s) do
    if pid, do: send(pid, {:openrouter_keys, body})

    case answers do
      [answer | rest] -> {:reply, answer, %{s | keys: {pid, rest}}}
      [] -> {:reply, {403, %{"error" => %{"code" => 403, "message" => "fake: none queued"}}}, s}
    end
  end

  def handle_call({:models, list}, _from, s), do: {:reply, :ok, %{s | list: list}}

  def handle_call({:list, entry}, _from, s),
    do: {:reply, :ok, %{s | list: if(is_list(s.list), do: s.list, else: []) ++ [entry]}}

  def handle_call(:list, _from, s) do
    reply =
      if is_list(s.list), do: {200, %{"data" => s.list}}, else: {s.list, %{"error" => "fake"}}

    {:reply, reply, s}
  end

  def handle_call({:listen, model, pid}, _from, s),
    do: {:reply, :ok, update(s, model, &%{&1 | listener: pid})}

  def handle_call({:push, model, pid, response}, _from, s) do
    s =
      update(s, model, fn
        %{waiting: [from | rest]} = m ->
          GenServer.reply(from, response)
          %{m | waiting: rest, listener: pid}

        m ->
          %{m | queue: m.queue ++ [response], listener: pid}
      end)

    {:reply, :ok, s}
  end

  def handle_call({:request, %{"model" => model} = body}, from, s) do
    m = Map.get(s.models, model, %{queue: [], waiting: [], listener: nil})
    if m.listener, do: send(m.listener, {:openrouter_request, model, body})

    case m.queue do
      [response | rest] -> {:reply, response, put_in(s.models[model], %{m | queue: rest})}
      [] -> {:noreply, put_in(s.models[model], %{m | waiting: m.waiting ++ [from]})}
    end
  end

  defp update(s, model, fun) do
    m = Map.get(s.models, model, %{queue: [], waiting: [], listener: nil})
    put_in(s.models[model], fun.(m))
  end

  defp build(opts) do
    case opts[:status] do
      nil ->
        {prompt, completion, cached} = opts[:usage] || {100, 10, 0}

        calls =
          for {name, args} <- opts[:calls] || [] do
            %{
              "id" => "toolu_fake_#{System.unique_integer([:positive])}",
              "type" => "function",
              "function" => %{"name" => to_string(name), "arguments" => arguments(name, args)}
            }
          end

        message =
          %{"role" => "assistant", "content" => opts[:text], "refusal" => nil}
          |> Map.put("reasoning", opts[:reasoning])
          |> then(&if calls == [], do: &1, else: Map.put(&1, "tool_calls", calls))
          |> then(
            &if d = opts[:reasoning_details], do: Map.put(&1, "reasoning_details", d), else: &1
          )

        {200,
         %{
           "id" => "gen-fake-#{System.unique_integer([:positive])}",
           "provider" => opts[:provider] || "Fake",
           "choices" => [
             %{
               "index" => 0,
               "finish_reason" =>
                 opts[:finish_reason] || if(calls == [], do: "stop", else: "tool_calls"),
               "message" => message
             }
           ],
           "usage" => %{
             "prompt_tokens" => prompt,
             "completion_tokens" => completion,
             "total_tokens" => prompt + completion,
             "prompt_tokens_details" => %{"cached_tokens" => cached, "cache_write_tokens" => 0},
             "cost" => opts[:cost] || 0.001
           }
         }, []}

      status ->
        {status,
         opts[:body] || %{"error" => %{"code" => status, "message" => "fake error #{status}"}},
         opts[:headers] || []}
    end
  end

  defp arguments(_, {:raw, term}), do: term
  defp arguments(:eval, code), do: Jason.encode!(%{code: code})
  defp arguments(:idle, nil), do: "{}"
  defp arguments(:idle, ms), do: Jason.encode!(%{wakeup_after: ms})
  defp arguments(_, raw) when is_binary(raw), do: raw
  defp arguments(_, args), do: Jason.encode!(args)

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(%{method: "GET"} = conn, _opts) do
      {status, body} = GenServer.call(Nano.FakeOpenRouter, :list)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end

    def call(conn, _opts) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 100_000_000)

      {status, body, headers} =
        if String.ends_with?(conn.request_path, "/auth/keys") do
          {status, body} = GenServer.call(Nano.FakeOpenRouter, {:exchange, Jason.decode!(raw)})
          {status, body, []}
        else
          Nano.FakeOpenRouter.request(Jason.decode!(raw))
        end

      body = if is_binary(body), do: body, else: Jason.encode!(body)

      headers
      |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end
  end
end
