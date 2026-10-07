defmodule Nano.FakeOpenRouter do
  @moduledoc """
  A scripted stand-in for OpenRouter's chat completions endpoint: a real HTTP server on a
  random localhost port, so agents exercise the whole `Req` path (bootstrap/PLAN.md decision 12).

      Nano.FakeOpenRouter.start()           # idempotent; points :openrouter_base_url at the fake
      model = Nano.FakeOpenRouter.model()   # a fresh slug; responses are queued per model, so
                                            # tests using different models don't interfere
      Nano.FakeOpenRouter.push(model, calls: [eval: "1 + 1"])
      Nano.FakeOpenRouter.push(model, calls: [{:eval, "x = 1"}, {:idle, 50}])  # idle: nil = no wakeup
      Nano.FakeOpenRouter.push(model, text: "done")
      Nano.FakeOpenRouter.push(model, status: 500)                      # an HTTP error
      {:ok, _pid} = NanoAgent.start(name: "alice", model: model)
      NanoAgent.notify("alice", :hi)
      assert_receive {:openrouter_request, ^model, body}                # decoded JSON body

  Every request for a model is also sent as `{:openrouter_request, model, body}` to the last
  process that called `push/2` or `listen/1` for it. A request for a model with nothing
  queued waits until something is pushed, so a test can hold an agent in `:thinking`.

  Response options: `text:`, `calls:` (a list of `{:eval, code}`, `{:idle, ms | nil}`, or
  `{name, args}` with args a map, a raw JSON string, or `{:raw, term}` to send `term` as the
  arguments value itself), `usage: {prompt, completion, cached}` (default `{100, 10, 0}`),
  `cost:` (default 0.001), `provider:`, `finish_reason:`, `reasoning:`, `reasoning_details:`. Or
  `status:` (and optionally `body:`) for an error response. The success shape mirrors what
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
    Application.put_env(:nano, :openrouter_base_url, "http://127.0.0.1:#{port}/api/v1")
  end

  @doc "A fresh model slug."
  def model, do: "fake/model-#{System.unique_integer([:positive])}"

  @doc "Queues one response for model; the caller receives that model's requests."
  def push(model, response),
    do: GenServer.call(__MODULE__, {:push, model, self(), build(response)})

  @doc "Makes the caller receive model's requests without queuing a response."
  def listen(model), do: GenServer.call(__MODULE__, {:listen, model, self()})

  @doc "What `GET /models` answers: a list of model maps (sent as `data`), or an HTTP status."
  def models(models_or_status), do: GenServer.call(__MODULE__, {:models, models_or_status})

  @doc false
  def request(body), do: GenServer.call(__MODULE__, {:request, body}, :infinity)

  @impl true
  def init(nil) do
    {:ok, server} =
      Bandit.start_link(plug: __MODULE__.Endpoint, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{port: port, models: %{}, list: 500}}
  end

  @impl true
  def handle_call(:port, _from, s), do: {:reply, s.port, s}

  def handle_call({:models, list}, _from, s), do: {:reply, :ok, %{s | list: list}}

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
         }}

      status ->
        {status,
         opts[:body] || %{"error" => %{"code" => status, "message" => "fake error #{status}"}}}
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
      {status, body} = Nano.FakeOpenRouter.request(Jason.decode!(raw))
      body = if is_binary(body), do: body, else: Jason.encode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end
  end
end
