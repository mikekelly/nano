defmodule Nano.SettingsTest do
  # Not async: the settings are node-wide, and these tests change them (and restart their process).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Nano.FakeOpenRouter, as: Fake
  alias Nano.TestSettings

  @endpoint NanoWeb.Endpoint
  @secret "sk-or-v1-0123456789abcdefSECRETwxyz"

  setup do
    Fake.start()
    saved = Application.get_env(:nano, :openrouter_backoff_ms)
    Application.put_env(:nano, :openrouter_backoff_ms, 1)
    on_exit(fn -> Application.put_env(:nano, :openrouter_backoff_ms, saved) end)
    :ok
  end

  defp path, do: Path.join(Application.fetch_env!(:nano, :state_dir), "settings.json")

  # Kills the settings process and waits for its supervisor to start it again.
  defp restart_settings do
    old = Process.whereis(Nano.Settings)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    wait_until(fn -> (pid = Process.whereis(Nano.Settings)) && pid != old end)
    :sys.get_state(Nano.Settings)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp entry(key), do: Enum.find(Nano.Ops.settings(), &(&1.key == key))

  defp start_agent(opts \\ []) do
    model = Fake.model()
    name = "s#{System.unique_integer([:positive])}"
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, opts))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    %{name: name, model: model, pid: pid, id: NanoAgent.info(name).id}
  end

  test "secret removal persists revocation, while authority failure is truthful and ordinary settings still work" do
    TestSettings.put(:eval_timeout_ms, 30000)
    TestSettings.put(:openrouter_api_key, "fixture-revoke")
    assert :ok = Nano.Ops.delete_setting(:openrouter_api_key)
    intent = Path.join([Nano.Safety.root(), "credentials", "intent-v1.json"])

    assert Jason.decode!(File.read!(intent))["entries"]["settings/openrouter_api_key"]["state"] ==
             "invalidated"

    File.write!(path(), ~s({"openrouter_api_key":"stale-fixture","eval_timeout_ms":30000}))
    restart_settings()
    assert Nano.Settings.get(:openrouter_api_key) == nil
    assert :ok = Nano.Safety.reconcile_credentials()
    TestSettings.put(:openrouter_api_key, "fixture-new")
    protected = File.read!(intent)
    File.rm!(intent)

    on_exit(fn ->
      File.write!(intent, protected)
      Nano.Safety.reconcile_credentials()
    end)

    assert {:error, message} = Nano.Ops.delete_setting(:openrouter_api_key)
    assert message =~ "maintenance"
    assert Nano.Settings.get(:openrouter_api_key) == "fixture-new"
    TestSettings.put(:eval_timeout_ms, 45000)
    assert Nano.Settings.get(:eval_timeout_ms) == 45000
    on_exit(fn -> Nano.Settings.delete(:eval_timeout_ms) end)
    conn = build_conn() |> Plug.Conn.put_req_header("x-nano-api-intent", "mutate")

    assert %{"error" => _} =
             conn |> delete("/api/settings/openrouter_api_key") |> json_response(422)

    {:ok, view, _} = live(build_conn(), "/?view=settings")
    view |> element("#setting-openrouter_api_key button", "clear") |> render_click()
    assert has_element?(view, "#setting-openrouter_api_key .error", "maintenance")
  end

  test "defaults, and a change saved 0600 that survives a restart of the process" do
    assert Nano.Settings.get(:eval_timeout_ms) == 30_000
    assert Nano.Settings.get(:network_policy) == "unrestricted outbound internet access"
    refute entry(:eval_timeout_ms).set

    TestSettings.put(:eval_timeout_ms, "45000")
    assert Nano.Settings.get(:eval_timeout_ms) == 45_000
    assert %{set: true, value: 45_000, default: 30_000, applies: :live} = entry(:eval_timeout_ms)
    assert File.stat!(path()).mode |> Bitwise.band(0o777) == 0o600
    assert Jason.decode!(File.read!(path()))["eval_timeout_ms"] == 45_000

    restart_settings()
    assert Nano.Settings.get(:eval_timeout_ms) == 45_000

    :ok = Nano.Settings.delete(:eval_timeout_ms)
    assert Nano.Settings.get(:eval_timeout_ms) == 30_000
    restart_settings()
    refute entry(:eval_timeout_ms).set
  end

  test "an unreadable file comes up with the defaults, logged once without its content" do
    good = File.read!(path())
    protected_key = Nano.Settings.get(:openrouter_api_key)

    on_exit(fn ->
      File.write!(path(), good)
      restart_settings()
    end)

    File.write!(path(), ~s|{"openrouter_api_key": "#{@secret}", oops|)

    log = capture_log(fn -> restart_settings() end)
    assert log =~ "ignoring damaged primary settings; protected credentials retained"
    refute log =~ @secret
    assert Nano.Settings.get(:openrouter_api_key) == protected_key
    assert Nano.Settings.get(:openrouter_base_url) == "https://openrouter.ai/api/v1"

    # A bad value in a good file goes back to its default; the rest are kept.
    File.write!(path(), ~s|{"eval_timeout_ms": -1, "result_max_bytes": 100}|)
    log = capture_log(fn -> restart_settings() end)
    assert log =~ ~s|ignoring "eval_timeout_ms"|

    assert {Nano.Settings.get(:eval_timeout_ms), Nano.Settings.get(:result_max_bytes)} ==
             {30_000, 100}
  end

  test "a bad value is refused, saying what is allowed and never repeating it" do
    for {key, value, message} <- [
          {:eval_timeout_ms, 0, "eval_timeout_ms must be a whole number from 1 to 4294967295"},
          {:eval_timeout_ms, "soon", "eval_timeout_ms must be a whole number from 1 to"},
          {:model_call_max_ms, 0,
           "model_call_max_ms must be a whole number from 1 to 4294967295"},
          {:node_max_tokens_per_hour, -5,
           "node_max_tokens_per_hour must be a whole number of 0 or more (0 = no limit)"},
          {:result_max_bytes, 9_000_000,
           "result_max_bytes must be a whole number from 1 to 8388608"},
          {:network_policy, "  ", "network_policy must be non-empty text"},
          {:openrouter_base_url, "ftp://x",
           "openrouter_base_url must be an http:// or https:// URL"},
          {:chatgpt_client_version, "latest", "chatgpt_client_version must be a version number"},
          {:system_prompt_file, "/no/such/file", "system_prompt_file must be a readable file"},
          {:openrouter_api_key, "two words", "openrouter_api_key must be a non-empty string"},
          {:openrouter_api_key, "", "openrouter_api_key must be a non-empty string"},
          {"nope here", 1, ~s|"nope here" is not a setting name|},
          {"SOME_TOKEN", 12, "SOME_TOKEN must be a string"}
        ] do
      assert {:error, refused} = Nano.Ops.put_setting(key, value)
      assert refused =~ message
    end

    assert {:error, refused} = Nano.Ops.put_setting(:openrouter_api_key, @secret <> " x")
    refute refused =~ @secret
    assert Nano.Settings.get(:eval_timeout_ms) == 30_000
  end

  test "secrets: never in the listing, the API, a log or the process's status" do
    log =
      capture_log(fn ->
        TestSettings.put(:openrouter_api_key, @secret)
        TestSettings.put("SOME_TOKEN", "token-#{@secret}")
        restart_settings()
      end)

    refute log =~ @secret
    assert Nano.Settings.get(:openrouter_api_key) == @secret
    assert Nano.Settings.get("SOME_TOKEN") == "token-#{@secret}"

    assert %{set: true, secret: true, value: nil, last4: "wxyz"} = entry(:openrouter_api_key)
    assert %{set: true, secret: true, value: nil, last4: "wxyz"} = entry("SOME_TOKEN")
    refute inspect(Nano.Ops.settings()) =~ @secret
    refute inspect(:sys.get_status(Nano.Settings)) =~ @secret
    body = build_conn() |> get("/api/settings") |> response(200)
    refute body =~ @secret

    # Crash reports print the last message, as format_status/1 leaves it.
    status = %{state: %{openrouter_api_key: @secret}, message: {:put, :x, @secret}}
    refute inspect(Nano.Settings.format_status(status)) =~ @secret
  end

  test "values of the operators' own: any string under a name, the node's own by env name" do
    TestSettings.put("EMPTY_TOKEN", "")
    restart_settings()
    assert Nano.Settings.get("EMPTY_TOKEN") == ""
    TestSettings.put("SOME_TOKEN", "abc")
    assert Nano.Settings.get("SOME_TOKEN") == "abc"
    assert Nano.Settings.get("OTHER") == nil
    # Named in any case, as a string or an atom: an agent may well ask for :some_token.
    assert Nano.Settings.get("some_token") == "abc"
    assert Nano.Settings.get(:some_token) == "abc"
    assert Nano.Settings.get(:SOME_TOKEN) == "abc"
    assert %{applies: :live, default: nil, last4: nil} = entry("SOME_TOKEN")
    assert :ok = Nano.Ops.delete_setting("SOME_TOKEN")
    assert entry("SOME_TOKEN") == nil
    assert {:error, "no setting SOME_TOKEN is set"} = Nano.Ops.delete_setting("SOME_TOKEN")

    # The node's own settings answer to their env names.
    TestSettings.put("EVAL_TIMEOUT_MS", "1234")
    assert Nano.Settings.get(:eval_timeout_ms) == 1234
    assert Nano.Settings.get("EVAL_TIMEOUT_MS") == 1234
    refute entry("EVAL_TIMEOUT_MS")
  end

  test "allowed_models: starts only on the models and levels the operators allow, from now on" do
    model = Fake.model()
    other = Fake.model()
    running = start_agent(reasoning: "high")

    assert {:error, refused} = Nano.Ops.put_setting(:allowed_models, "#{model} warp")
    assert refused =~ "allowed_models must be any, or entries separated by semicolons"
    TestSettings.put(:allowed_models, " #{model} low,medium ;#{other}")
    assert Nano.Settings.get(:allowed_models) == "#{model} low medium; #{other}"

    start = fn model, reasoning ->
      name = "s#{System.unique_integer([:positive])}"
      on_exit(fn -> Nano.Ops.stop_agent(name) end)
      NanoAgent.start([name: name] ++ Fake.opts(model, reasoning: reasoning))
    end

    assert {:ok, _} = start.(model, "low")
    assert {:ok, _} = start.(other, "max")

    assert {:error, "reasoning \"high\" is not allowed for " <> rest} = start.(model, "high")
    assert rest =~ "(setting allowed_models); allowed: low, medium"

    assert {:error, refused} = start.(running.model, "low")
    assert refused =~ "#{running.model} is not allowed on this node (setting allowed_models)"
    assert refused =~ "allowed: "
    assert refused =~ "#{model} at low, medium"
    assert refused =~ other

    # Agents already running carry on.
    assert NanoAgent.info(running.name).halted == nil

    # What the start form offers: only the allowed models, at their allowed levels.
    listed = Nano.Model.allow(:openrouter, Nano.OpenRouter.models())
    assert Enum.map(listed, & &1.id) |> Enum.sort() == Enum.sort([model, other])
    assert %{reasoning_levels: ["low", "medium"]} = Enum.find(listed, &(&1.id == model))

    TestSettings.put(:allowed_models, "any")
    assert {:ok, _} = start.(running.model, "high")
  end

  test "removing OpenRouter's key halts the agents on it and refuses new ones until it is back" do
    TestSettings.put(:openrouter_api_key, "test-key")
    a = start_agent()
    Nano.Log.subscribe(a.id)

    :ok = Nano.Ops.delete_setting(:openrouter_api_key)
    :sys.get_state(a.pid)
    assert NanoAgent.info(a.name).halted == :provider_unavailable

    assert Enum.any?(Nano.Log.read(a.id), fn e ->
             e["type"] == "harness_note" and
               e["text"] =~
                 "OpenRouter, the provider of your model #{a.model}, has been turned off by " <>
                   "an operator: this node no longer has its API key, so I have halted you"
           end)

    assert {:error, "OpenRouter is off on this node" <> _} =
             NanoAgent.start([name: "s_refused"] ++ Fake.opts(Fake.model()))

    assert %{"providers" => %{"openrouter" => false}} =
             build_conn() |> get("/api") |> json_response(200)

    # Un-halted while it is still off: halted again, without a call.
    send(a.pid, :hello)
    NanoAgent.unhalt(a.name)
    :sys.get_state(a.pid)
    refute_receive {:openrouter_request, _, _}, 100
    assert NanoAgent.info(a.name).halted == :provider_unavailable

    # Back on: un-halting works.
    :ok = Nano.Ops.put_setting("OPENROUTER_API_KEY", "test-key")
    Fake.push(a.model, text: "ok")
    NanoAgent.unhalt(a.name)
    assert_receive {:openrouter_request, model, _}, 2_000
    assert model == a.model
    :sys.get_state(a.pid)
    assert NanoAgent.info(a.name).halted == nil
  end

  test "what the system prompt states is the agent's own: kept at restart, new for new agents" do
    TestSettings.put(:result_max_bytes, 100)
    TestSettings.put(:network_policy, "none at all")
    a = start_agent()
    assert NanoAgent.info(a.name).system_prompt =~ "Network access: none at all."
    assert NanoAgent.info(a.name).system_prompt =~ "is cut\nat 100 bytes"

    TestSettings.put(:result_max_bytes, 5_000)
    TestSettings.put(:network_policy, "everything")

    # Its results are still cut where its prompt says.
    Fake.push(a.model, calls: [eval: ~s|String.duplicate("x", 300)|])
    Fake.push(a.model, text: "done")
    send(a.pid, :go)
    assert_receive {:openrouter_request, _, _}, 2_000
    assert_receive {:openrouter_request, _, body}, 2_000
    assert [%{"text" => result}] = List.last(body["messages"])["content"]
    assert result =~ "[cut at 100 of 302 bytes"

    # And after a restart, which renders the prompt again.
    :sys.get_state(a.pid)
    Process.exit(a.pid, :kill)
    wait_until(fn -> (pid = NanoAgent.whereis(a.name)) && pid != a.pid end)
    :sys.get_state(NanoAgent.whereis(a.name))
    prompt = NanoAgent.info(a.name).system_prompt
    assert prompt =~ "Network access: none at all."
    assert prompt =~ "at 100 bytes"

    b = start_agent()
    assert NanoAgent.info(b.name).system_prompt =~ "Network access: everything."
    assert NanoAgent.info(b.name).system_prompt =~ "at 5000 bytes"
  end

  test "the API: list, set and clear; 422 and 404 say why" do
    conn = fn method, path, body ->
      build_conn()
      |> then(fn conn ->
        if method in [:get, :head, :options],
          do: conn,
          else: Plug.Conn.put_req_header(conn, "x-nano-api-intent", "mutate")
      end)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> dispatch(@endpoint, method, path, body && Jason.encode!(body))
    end

    list = conn.(:get, "/api/settings", nil) |> json_response(200)

    assert Enum.map(list, & &1["key"]) |> Enum.take(2) == [
             "openrouter_api_key",
             "node_max_tokens_per_hour"
           ]

    TestSettings.put(:eval_timeout_ms, 30_000)

    assert %{"key" => "eval_timeout_ms", "value" => 1000, "set" => true, "applies" => "live"} =
             conn.(:put, "/api/settings/eval_timeout_ms", %{value: 1000}) |> json_response(200)

    assert %{"key" => "eval_timeout_ms", "value" => 30_000, "set" => false} =
             conn.(:delete, "/api/settings/eval_timeout_ms", nil) |> json_response(200)

    assert %{"error" => "eval_timeout_ms must be a whole number" <> _} =
             conn.(:put, "/api/settings/eval_timeout_ms", %{value: "x"}) |> json_response(422)

    assert %{"error" => "value is required"} =
             conn.(:put, "/api/settings/eval_timeout_ms", %{}) |> json_response(422)

    assert %{"error" => "no setting SOME_TOKEN is set"} =
             conn.(:delete, "/api/settings/SOME_TOKEN", nil) |> json_response(404)

    TestSettings.put(:openrouter_api_key, "test-key")

    assert %{"key" => "openrouter_api_key", "set" => true, "value" => nil, "last4" => "wxyz"} =
             conn.(:put, "/api/settings/OPENROUTER_API_KEY", %{value: @secret})
             |> json_response(200)

    TestSettings.delete("SOME_TOKEN")

    assert %{"key" => "SOME_TOKEN", "set" => true, "value" => nil, "secret" => true} =
             conn.(:put, "/api/settings/SOME_TOKEN", %{value: "v"}) |> json_response(200)

    assert %{"key" => "SOME_TOKEN", "set" => false} =
             conn.(:delete, "/api/settings/SOME_TOKEN", nil) |> json_response(200)
  end

  test "the dashboard: every setting, keys masked, save and clear each, refusals beside it" do
    TestSettings.put(:openrouter_api_key, @secret)
    TestSettings.put(:network_policy, "unrestricted outbound internet access")
    {:ok, view, html} = live(build_conn(), "/?view=settings")
    refute html =~ @secret
    assert has_element?(view, "#setting-openrouter_api_key input[type=password][value='']")
    assert has_element?(view, "#setting-openrouter_api_key", "set, ends …wxyz")
    assert has_element?(view, "#setting-network_policy input[type=text]")

    view
    |> form("#setting-network_policy", %{value: "only the providers"})
    |> render_submit()

    assert Nano.Settings.get(:network_policy) == "only the providers"
    assert has_element?(view, "#setting-network_policy", "reset to default")

    view |> form("#setting-eval_timeout_ms", %{value: "never"}) |> render_submit()
    assert has_element?(view, "#setting-eval_timeout_ms .error", "must be a whole number")

    view |> element("#setting-network_policy button", "reset to default") |> render_click()
    assert Nano.Settings.get(:network_policy) == "unrestricted outbound internet access"

    view |> element("#setting-openrouter_api_key button", "clear") |> render_click()
    assert Nano.Settings.get(:openrouter_api_key) == nil
    assert has_element?(view, "#setting-openrouter_api_key", "not set")

    TestSettings.delete("SOME_TOKEN")
    view |> form("#setting-new", %{name: "SOME_TOKEN", value: "v"}) |> render_submit()
    assert Nano.Settings.get("SOME_TOKEN") == "v"
    assert has_element?(view, "#setting-SOME_TOKEN", "set")
    view |> form("#setting-new", %{name: "no good", value: "v"}) |> render_submit()
    assert has_element?(view, "#setting-new .error", "is not a setting name")
  end

  describe "bin/push-settings" do
    setup do
      {:ok, server} =
        start_supervised(
          {Bandit, plug: NanoWeb.Endpoint, ip: :loopback, port: 0, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      %{url: "http://127.0.0.1:#{port}"}
    end

    test "sets every KEY=value line, the host's too, skipping only comments and empty values; prints names, never values",
         ctx do
      for key <- [:openrouter_api_key, :eval_timeout_ms, :network_policy, "SOME_TOKEN"],
          do: TestSettings.put(key, if(key == :eval_timeout_ms, do: 30_000, else: "x"))

      for name <- ~w(NANO_CHECKOUT NODE_COOKIE PORT EMPTY), do: TestSettings.delete(name)

      env =
        Path.join(Application.fetch_env!(:nano, :test_dir), "push-#{System.unique_integer()}.env")

      File.write!(env, """
      # a comment
      OPENROUTER_API_KEY=#{@secret}

      EVAL_TIMEOUT_MS="45000"
      export NETWORK_POLICY=only "quoted" \\ text\r
      SOME_TOKEN='tok #{@secret}'
      NANO_CHECKOUT=../elsewhere
      NODE_COOKIE=cookie
      PORT=4001
      EMPTY=
      # NETWORK_POLICY=commented out
        # PORT=indented comment
      """)

      {out, 0} = System.cmd("sh", ["bin/push-settings", ctx.url, env], stderr_to_stdout: true)
      refute out =~ @secret

      assert out ==
               "settings set from #{env}: OPENROUTER_API_KEY EVAL_TIMEOUT_MS NETWORK_POLICY " <>
                 "SOME_TOKEN NANO_CHECKOUT NODE_COOKIE PORT\n"

      assert Nano.Settings.get(:openrouter_api_key) == @secret
      assert Nano.Settings.get(:eval_timeout_ms) == 45_000
      assert Nano.Settings.get(:network_policy) == ~s|only "quoted" \\ text|
      assert Nano.Settings.get("SOME_TOKEN") == "tok #{@secret}"
      assert Nano.Settings.get("NANO_CHECKOUT") == "../elsewhere"
      assert Nano.Settings.get("NODE_COOKIE") == "cookie"
      assert Nano.Settings.get("PORT") == "4001"
      assert Nano.Settings.get("EMPTY") == nil

      # A refusal is reported by name, and the script fails.
      File.write!(env, "EVAL_TIMEOUT_MS=never\n")
      {out, 1} = System.cmd("sh", ["bin/push-settings", ctx.url, env], stderr_to_stdout: true)
      assert out =~ "could not set EVAL_TIMEOUT_MS: "
      assert out =~ "must be a whole number"
      assert Nano.Settings.get(:eval_timeout_ms) == 45_000
    end
  end
end
