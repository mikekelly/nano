defmodule Nano.OpenRouterAuthTest do
  # Not async: the OpenRouter key is a node-wide setting, and the fake is node-wide.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nano.FakeOpenRouter, as: Fake
  alias Nano.OpenRouter.Auth

  @endpoint NanoWeb.Endpoint
  @secret "sk-or-v1-fake-secret-0123456789abcdef"

  setup do
    Fake.start()
    Fake.keys([])
    # The key as the test left it is put back afterwards.
    Nano.TestSettings.delete(:openrouter_api_key)
  end

  # Starts a login as the dashboard's Connect OpenRouter link does: the query of the address
  # on OpenRouter it sends the browser to.
  defp connect do
    page = get(build_conn(), "/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, page.resp_body)

    conn =
      page
      |> recycle()
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/openrouter/connect", URI.encode_query(%{_csrf_token: token}))

    url = URI.parse(redirected_to(conn, 302))
    assert url.path == "/auth"
    URI.decode_query(url.query)
  end

  defp callback(params) do
    conn = get(build_conn(), "/openrouter/callback?" <> URI.encode_query(params))
    assert redirected_to(conn, 302) == "/"
    conn
  end

  defp challenge(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  test "Connect OpenRouter: PKCE to OpenRouter and back; the key becomes the setting, never shown or logged" do
    Logger.put_process_level(self(), :debug)

    log =
      capture_log([level: :debug], fn ->
        query = connect()

        assert %{
                 "callback_url" => "http://localhost:4000/openrouter/callback",
                 "code_challenge_method" => "S256",
                 "code_challenge" => challenge,
                 "state" => state,
                 "key_label" => "Nano Agent"
               } = query

        Fake.keys([{200, %{"key" => @secret, "user_id" => "user_1"}}])
        conn = callback(%{"code" => "auth-code", "state" => state})
        refute Phoenix.Flash.get(conn.assigns.flash, :openrouter_error)

        # The code, with the verifier whose S256 hash was the challenge.
        assert_received {:openrouter_keys,
                         %{
                           "code" => "auth-code",
                           "code_verifier" => verifier,
                           "code_challenge_method" => "S256"
                         }}

        assert challenge(verifier) == challenge
        refute query |> Map.values() |> Enum.member?(verifier)
        assert Nano.Settings.get(:openrouter_api_key) == @secret

        # A state is good once.
        conn = callback(%{"code" => "auth-code", "state" => state})
        assert Phoenix.Flash.get(conn.assigns.flash, :openrouter_error) =~ "already used"
        refute_received {:openrouter_keys, _}

        # Never in the API or on the dashboard: only its last four characters.
        api = build_conn() |> get("/api/settings") |> response(200)
        refute api =~ @secret

        assert %{"openrouter" => true} =
                 (build_conn() |> get("/api") |> json_response(200))["providers"]

        {:ok, view, html} = live(build_conn(), "/")
        refute html =~ @secret
        assert has_element?(view, "#providers .provider.on.connected", "OpenRouter")
        assert has_element?(view, "#openrouter", "connected with the key ending …cdef")
      end)

    refute log =~ @secret
  end

  test "a callback with an unknown, expired or used state, or no code, is refused and stores nothing" do
    Fake.keys([{200, %{"key" => @secret}}])
    flash = &Phoenix.Flash.get(&1.assigns.flash, :openrouter_error)

    conn = callback(%{"code" => "c", "state" => "forged"})
    assert flash.(conn) =~ "unknown, already used or more than 15 minutes old"

    # Expired: logins last 15 minutes, so move this one's deadline into the past.
    %{"state" => state} = connect()
    :sys.replace_state(Auth, &put_in(&1[state].expires_at, 0))
    assert flash.(callback(%{"code" => "c", "state" => state})) =~ "more than 15 minutes old"

    # Denied: OpenRouter sends no code back.
    %{"state" => state} = connect()
    assert flash.(callback(%{"state" => state})) =~ "no authorization"

    refute_received {:openrouter_keys, _}
    assert Nano.Settings.get(:openrouter_api_key) == nil

    # The verifier is never in what the process shows of itself.
    %{"state" => state} = connect()
    refute inspect(:sys.get_status(Auth)) =~ :sys.get_state(Auth)[state].verifier

    # OpenRouter refusing the exchange: its status and message, never its body.
    Fake.keys([
      {403, %{"error" => %{"code" => 403, "message" => "Invalid code or code_verifier"}}}
    ])

    conn = callback(%{"code" => "c", "state" => state})
    assert flash.(conn) =~ "HTTP 403: Invalid code or code_verifier"
    assert Nano.Settings.get(:openrouter_api_key) == nil

    # The error shows in the start form's OpenRouter panel, with OpenRouter chosen.
    {:ok, view, _} = live(recycle(conn), "/")
    assert has_element?(view, "#openrouter .error", "HTTP 403: Invalid code or code_verifier")
    assert has_element?(view, "#providers .provider.on", "OpenRouter")
  end

  test "the start form lists every provider with its state; OpenRouter connects by pasting a key and disconnects" do
    {:ok, view, html} = live(build_conn(), "/")

    # Neither connected: both listed, OpenRouter chosen, its ways to connect shown.
    assert has_element?(view, "#providers .provider.disconnected", "OpenRouter")
    assert has_element?(view, "#providers .provider.disconnected", "ChatGPT")
    assert has_element?(view, "#providers .provider.on", "OpenRouter")
    assert html =~ "not connected"

    assert has_element?(
             view,
             ~s|#openrouter form[action="/openrouter/connect"] button|,
             "Connect OpenRouter"
           )

    assert has_element?(view, "#openrouter-key input[type=password][name=key]")
    assert has_element?(view, "#start button.primary[disabled]")
    assert has_element?(view, "#start .actions", "connect OpenRouter first")

    # Choosing the other offers its own connect.
    view |> element("#providers button", "ChatGPT") |> render_click()
    assert has_element?(view, "#providers .provider.on", "ChatGPT")
    assert has_element?(view, "#chatgpt button", "Connect ChatGPT")
    refute has_element?(view, "#openrouter")
    view |> element("#providers button", "OpenRouter") |> render_click()

    # A bad key is refused, and never repeated.
    html = view |> form("#openrouter-key", %{key: "two words"}) |> render_submit()
    assert has_element?(view, "#openrouter .error", "must be a non-empty string without spaces")
    refute html =~ "two words"

    Fake.models([%{"id" => "fake/listed", "name" => "Listed", "context_length" => 1000}])
    :persistent_term.erase({Nano.OpenRouter, :models})
    on_exit(fn -> :persistent_term.erase({Nano.OpenRouter, :models}) end)

    html = view |> form("#openrouter-key", %{key: @secret}) |> render_submit()
    refute html =~ @secret
    assert Nano.Settings.get(:openrouter_api_key) == @secret
    assert has_element?(view, "#providers .provider.on.connected", "OpenRouter")
    refute has_element?(view, "#start button.primary[disabled]")
    # Its models arrive.
    assert has_element?(view, "#start-model[placeholder='type to filter 1 models']")

    # Disconnect from the start form...
    view |> element("#openrouter button", "disconnect") |> render_click()
    assert Nano.Settings.get(:openrouter_api_key) == nil
    assert has_element?(view, "#openrouter", "not connected")

    # ...or from Settings.
    Nano.Settings.put(:openrouter_api_key, @secret)
    {:ok, view, _} = live(build_conn(), "/?view=settings")
    assert has_element?(view, "#provider-openrouter", "connected with the key ending …cdef")
    assert has_element?(view, "#provider-chatgpt", "not connected")
    refute has_element?(view, "#provider-chatgpt button")
    view |> element("#provider-openrouter button", "disconnect") |> render_click()
    assert Nano.Settings.get(:openrouter_api_key) == nil
    assert has_element?(view, "#provider-openrouter", "not connected")
  end

  test "the sign-in process refuses or ignores what it does not know" do
    pid = Process.whereis(Auth)
    %{"state" => state} = connect()
    GenServer.cast(Auth, :junk)
    send(Auth, :junk)
    assert GenServer.call(Auth, :junk) == {:error, :unknown_call}
    assert Process.whereis(Auth) == pid
    assert Map.has_key?(:sys.get_state(Auth), state)
  end

  test "CSRF form is required before pending insertion; safe methods cannot initiate or exchange" do
    Auth.invalidate_pending()

    for token <- [nil, "invalid"] do
      page = get(build_conn(), "/")
      before = map_size(:sys.get_state(Auth))
      body = if token, do: URI.encode_query(%{_csrf_token: token}), else: ""

      assert_error_sent 403, fn ->
        page
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/openrouter/connect", body)
      end

      assert map_size(:sys.get_state(Auth)) == before
    end

    for method <- [:get, :head] do
      assert dispatch(build_conn(), @endpoint, method, "/openrouter/connect", nil).status == 404
      assert map_size(:sys.get_state(Auth)) == 0
    end

    %{"state" => state} = connect()
    Fake.keys([{200, %{"key" => @secret}}])
    path = "/openrouter/callback?" <> URI.encode_query(%{state: state, code: "c"})

    for method <- [:head, :options] do
      assert dispatch(build_conn(), @endpoint, method, path, nil).status == 405
      assert Map.has_key?(:sys.get_state(Auth), state)
      refute_received {:openrouter_keys, _}
      assert Nano.Settings.get(:openrouter_api_key) == nil
    end

    callback(%{"state" => state, "code" => "c"})
    assert_received {:openrouter_keys, _}
    assert Nano.Settings.get(:openrouter_api_key) == @secret
  end

  test "hot policy transition invalidates old pending attempts only, then new flow succeeds" do
    Auth.invalidate_pending()
    %{"state" => state} = connect()
    # Representative old readable pending map lacks callback binding.
    :sys.replace_state(Auth, fn map -> Map.update!(map, state, &Map.delete(&1, :callback_url)) end)

    Nano.Settings.put(:openrouter_api_key, @secret)
    assert Auth.invalidate_pending() == 1
    assert Nano.Settings.get(:openrouter_api_key) == @secret
    callback(%{"state" => state, "code" => "old"})
    refute_received {:openrouter_keys, _}
    %{"state" => fresh} = connect()
    Fake.keys([{200, %{"key" => @secret}}])
    callback(%{"state" => fresh, "code" => "fresh"})
    assert_received {:openrouter_keys, _}
  end

  test "callback policy is fixed, host spoofing irrelevant, invalid policy cannot insert or exchange" do
    Auth.invalidate_pending()
    saved = Application.fetch_env!(:nano, :openrouter_callback_url)
    on_exit(fn -> Application.put_env(:nano, :openrouter_callback_url, saved) end)
    assert {:ok, url} = Auth.login(saved)
    query = URI.parse(url).query |> URI.decode_query()
    assert query["callback_url"] == saved
    assert {:error, _} = Auth.login("http://evil.example/openrouter/callback")
    count = map_size(:sys.get_state(Auth))

    for invalid <- [
          "http://evil.example/openrouter/callback",
          saved <> "?x",
          "http://localhost:4000/wrong"
        ] do
      Application.put_env(:nano, :openrouter_callback_url, invalid)
      page = get(build_conn(), "/")
      [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, page.resp_body)

      conn =
        page
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/openrouter/connect", URI.encode_query(%{_csrf_token: token}))

      assert conn.status == 503
      assert map_size(:sys.get_state(Auth)) == count
    end

    callback(%{"state" => query["state"], "code" => "invalid-policy"})
    refute_received {:openrouter_keys, _}
    assert Nano.Settings.get(:openrouter_api_key) == nil
  end
end
