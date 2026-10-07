defmodule Nano.FakeChatGPT do
  @moduledoc """
  A scripted stand-in for the ChatGPT subscription: the Codex backend (`POST /responses` as a
  server-sent event stream, `GET /models`) and the OAuth server (device-code login, token
  exchange and refresh). A real HTTP server on a random localhost port, like
  `Nano.FakeOpenRouter`, so the whole `Req` path runs.

      Nano.FakeChatGPT.start()                 # idempotent; points :chatgpt_base_url and :chatgpt_auth_url here
      Nano.FakeChatGPT.listen()                # the caller receives every request (below)
      Nano.FakeChatGPT.auth(:poll, [{403, %{}}, {200, :approved}])   # queued answers per endpoint
      model = Nano.FakeChatGPT.model()         # a fresh slug (without the openai-codex/ prefix)
      Nano.FakeChatGPT.push(model, calls: [eval: "1 + 1"], reasoning: "thinking about it")
      Nano.FakeChatGPT.push(model, status: 429, body: %{"error" => %{"type" => "usage_limit_reached"}})

  Requests arrive at the listener as `{:chatgpt_auth, endpoint, body}` (endpoint `:usercode`,
  `:poll` or `:token`) and `{:chatgpt_request, model, body, headers}`. A model with nothing
  queued holds its request until something is pushed.

  Auth answers, when nothing is queued: usercode 200 with code "FAKE-CODE" and interval 0;
  poll 403 (pending); token 200 with fresh tokens (`tokens/1`), whatever the grant. A queued
  `{200, :approved}` on `:poll` answers with an authorization code and verifier.

  Response options: `text:`, `calls:` (as in `Nano.FakeOpenRouter`), `reasoning:` (a summary
  text; the item also carries encrypted content `"enc-<n>"`), `usage: {input, output,
  cached}` (default `{100, 10, 0}`), `incomplete:` (a reason), or `status:` with `body:` for an
  HTTP error, or `failed:` (an error map) for a stream that ends in `response.failed`.
  """
  use GenServer

  @doc "Starts the fake once and points the app at it."
  def start do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    port = GenServer.call(__MODULE__, :port)
    Application.put_env(:nano, :chatgpt_base_url, "http://127.0.0.1:#{port}/backend-api/codex")
    Application.put_env(:nano, :chatgpt_auth_url, "http://127.0.0.1:#{port}")
  end

  @doc """
  A fresh model name (without the openai-codex/ prefix), added to the models `GET /models`
  lists (a 272,000-token window, every reasoning level, default "none"), and the node's cached
  list dropped, so that agents can be started on it once the subscription is connected.
  """
  def model do
    slug = "gpt-fake-#{System.unique_integer([:positive])}"
    efforts = for e <- ~w(none minimal low medium high xhigh max), do: %{"effort" => e}

    entry = %{
      "slug" => slug,
      "context_window" => 272_000,
      "supported_reasoning_levels" => efforts,
      "default_reasoning_level" => "none"
    }

    GenServer.call(__MODULE__, {:list, entry})
    :persistent_term.erase({Nano.ChatGPT, :models})
    slug
  end

  @doc "Makes the caller receive every request; clears the auth queues."
  def listen, do: GenServer.call(__MODULE__, {:listen, self()})

  @doc "Queues answers (`{status, body}`) for an auth endpoint."
  def auth(endpoint, answers), do: GenServer.call(__MODULE__, {:auth, endpoint, answers})

  def push(model, response), do: GenServer.call(__MODULE__, {:push, model, response})

  @doc "What `GET /models` answers: a list of model maps (sent as `models`), or an HTTP status."
  def models(list_or_status), do: GenServer.call(__MODULE__, {:models, list_or_status})

  @doc """
  A token response as the OAuth server sends it: unsigned JWTs whose claims carry the account
  id, plan and email, the access token expiring in `expires_in` seconds (default an hour).
  """
  def tokens(opts \\ []) do
    n = System.unique_integer([:positive])
    exp = System.system_time(:second) + Keyword.get(opts, :expires_in, 3600)
    auth = %{"chatgpt_account_id" => "acct-fake", "chatgpt_plan_type" => "plus"}

    %{
      "id_token" => jwt(%{"email" => "me@example.com", "https://api.openai.com/auth" => auth}),
      "access_token" => jwt(%{"exp" => exp, "n" => n, "https://api.openai.com/auth" => auth}),
      "refresh_token" => "refresh-#{n}",
      "expires_in" => Keyword.get(opts, :expires_in, 3600)
    }
  end

  defp jwt(claims),
    do: "e30." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".sig"

  @doc false
  def request(kind, body, headers),
    do: GenServer.call(__MODULE__, {:request, kind, body, headers}, :infinity)

  @impl true
  def init(nil) do
    {:ok, server} =
      Bandit.start_link(plug: __MODULE__.Endpoint, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{port: port, listener: nil, auth: %{}, models: %{}, list: 500}}
  end

  @impl true
  def handle_call(:port, _from, s), do: {:reply, s.port, s}
  def handle_call({:listen, pid}, _from, s), do: {:reply, :ok, %{s | listener: pid, auth: %{}}}

  def handle_call({:auth, endpoint, answers}, _from, s),
    do: {:reply, :ok, update_in(s.auth[endpoint], &((&1 || []) ++ answers))}

  def handle_call({:models, list}, _from, s), do: {:reply, :ok, %{s | list: list}}

  def handle_call({:list, entry}, _from, s),
    do: {:reply, :ok, %{s | list: if(is_list(s.list), do: s.list, else: []) ++ [entry]}}

  def handle_call({:push, model, response}, _from, s) do
    m = Map.get(s.models, model, %{queue: [], waiting: []})

    m =
      case m.waiting do
        [from | rest] ->
          GenServer.reply(from, build(response))
          %{m | waiting: rest}

        [] ->
          %{m | queue: m.queue ++ [build(response)]}
      end

    {:reply, :ok, put_in(s.models[model], m)}
  end

  def handle_call({:request, :models, _, _}, _from, s) do
    reply =
      if is_list(s.list),
        do: {200, "application/json", Jason.encode!(%{"models" => s.list})},
        else: {s.list, "application/json", "{}"}

    {:reply, reply, s}
  end

  def handle_call({:request, :responses, %{"model" => model} = body, headers}, from, s) do
    if s.listener, do: send(s.listener, {:chatgpt_request, model, body, headers})
    m = Map.get(s.models, model, %{queue: [], waiting: []})

    case m.queue do
      [response | rest] -> {:reply, response, put_in(s.models[model], %{m | queue: rest})}
      [] -> {:noreply, put_in(s.models[model], %{m | waiting: m.waiting ++ [from]})}
    end
  end

  def handle_call({:request, endpoint, body, _headers}, _from, s) do
    if s.listener, do: send(s.listener, {:chatgpt_auth, endpoint, body})

    {answer, rest} =
      case s.auth[endpoint] do
        [answer | rest] -> {answer, rest}
        _ -> {default(endpoint), []}
      end

    {status, body} =
      case answer do
        {200, :approved} ->
          {200, %{"authorization_code" => "authcode", "code_verifier" => "verifier"}}

        answer ->
          answer
      end

    {:reply, {status, "application/json", Jason.encode!(body)}, put_in(s.auth[endpoint], rest)}
  end

  defp default(:usercode),
    do: {200, %{"device_auth_id" => "dev-1", "user_code" => "FAKE-CODE", "interval" => "0"}}

  defp default(:poll), do: {403, %{"error" => %{"code" => "deviceauth_authorization_pending"}}}
  defp default(:token), do: {200, tokens()}

  # A Responses API event stream, as the Codex backend sends it.
  defp build(opts) do
    cond do
      status = opts[:status] ->
        body = opts[:body] || %{"error" => %{"message" => "fake error #{status}"}}
        {status, "application/json", Jason.encode!(body)}

      failed = opts[:failed] ->
        sse(200, [%{"type" => "response.failed", "response" => %{"error" => failed}}])

      true ->
        {input, output, cached} = opts[:usage] || {100, 10, 0}
        n = System.unique_integer([:positive])

        reasoning =
          for text <- List.wrap(opts[:reasoning]) do
            %{
              "type" => "reasoning",
              "id" => "rs_#{n}",
              "summary" => [%{"type" => "summary_text", "text" => text}],
              "encrypted_content" => "enc-#{n}"
            }
          end

        message =
          for text <- List.wrap(opts[:text]) do
            %{
              "type" => "message",
              "id" => "msg_#{n}",
              "role" => "assistant",
              "status" => "completed",
              "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
            }
          end

        calls =
          for {name, args} <- opts[:calls] || [] do
            %{
              "type" => "function_call",
              "id" => "fc_#{System.unique_integer([:positive])}",
              "call_id" => "call_#{System.unique_integer([:positive])}",
              "name" => to_string(name),
              "arguments" => arguments(name, args),
              "status" => "completed"
            }
          end

        items = reasoning ++ message ++ calls

        usage = %{
          "input_tokens" => input,
          "input_tokens_details" => %{"cached_tokens" => cached},
          "output_tokens" => output,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => input + output
        }

        done =
          if reason = opts[:incomplete],
            do: %{
              "type" => "response.incomplete",
              "response" => %{
                "status" => "incomplete",
                "incomplete_details" => %{"reason" => reason},
                "usage" => usage
              }
            },
            else: %{
              "type" => "response.completed",
              "response" => %{"id" => "resp_#{n}", "status" => "completed", "usage" => usage}
            }

        events =
          [%{"type" => "response.created", "response" => %{"id" => "resp_#{n}"}}] ++
            for(item <- items, do: %{"type" => "response.output_item.done", "item" => item}) ++
            [done]

        sse(200, events)
    end
  end

  defp sse(status, events) do
    body = Enum.map_join(events, fn e -> "event: #{e["type"]}\ndata: #{Jason.encode!(e)}\n\n" end)
    {status, "text/event-stream", body}
  end

  defp arguments(:eval, code), do: Jason.encode!(%{code: code})
  defp arguments(:idle, nil), do: "{}"
  defp arguments(:idle, ms), do: Jason.encode!(%{wakeup_after: ms})
  defp arguments(_, raw) when is_binary(raw), do: raw
  defp arguments(_, args), do: Jason.encode!(args)

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug

    @routes %{
      "/api/accounts/deviceauth/usercode" => :usercode,
      "/api/accounts/deviceauth/token" => :poll,
      "/oauth/token" => :token,
      "/backend-api/codex/responses" => :responses,
      "/backend-api/codex/models" => :models
    }

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
      conn = Plug.Conn.fetch_query_params(conn)

      body =
        case Plug.Conn.get_req_header(conn, "content-type") do
          ["application/x-www-form-urlencoded" <> _] -> URI.decode_query(raw)
          _ when raw == "" -> %{}
          _ -> Jason.decode!(raw)
        end

      {status, type, out} =
        Nano.FakeChatGPT.request(Map.fetch!(@routes, conn.request_path), body, conn.req_headers)

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(status, out)
    end
  end
end
