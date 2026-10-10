defmodule NanoWeb.ApiGuardEndpointTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  @endpoint NanoWeb.Endpoint

  defp request(method, path, bytes \\ "", headers \\ []) do
    conn = build_conn() |> Map.put(:req_headers, headers)
    dispatch(conn, @endpoint, method, path, if(bytes == "", do: nil, else: bytes))
  end

  @intent {"x-nano-api-intent", "mutate"}
  @json {"content-type", "application/json"}
  defp rejected(conn, status, code) do
    assert conn.status == status

    if conn.method != "HEAD",
      do: assert(%{"error" => ^code, "message" => _} = json_response(conn, status))
  end

  test "A form and B empty text/plain query eval attacks never execute actual code" do
    code = "send(:erlang.list_to_pid(#{inspect(:erlang.pid_to_list(self()))}), :guard_executed)"
    query = URI.encode_query(%{code: code})

    for {body, headers} <- [
          {query, [{"content-type", "application/x-www-form-urlencoded"}]},
          {"", [{"content-type", "text/plain"}]}
        ] do
      request(:post, "/api/eval?" <> query, body, headers) |> rejected(403, "api_intent_required")
      refute_received :guard_executed
    end
  end

  test "intent and origin matrix through original Endpoint boundary" do
    origins = [
      nil,
      "http://localhost:4000",
      "http://127.0.0.1:4000",
      "http://[::1]:4000",
      "https://evil.example",
      "null",
      "http://localhost:4000/",
      "http://localhost:4000, http://localhost:4000"
    ]

    intents = [[], [@intent], [@intent, @intent], [{"x-nano-api-intent", "other"}]]

    for origin <- origins,
        intent <- intents,
        path <- ["/api/eval", "/api/agents/no_such_agent/stop"] do
      headers = intent ++ if(origin, do: [{"origin", origin}], else: []) ++ [@json]
      conn = request(:post, path, "{}", headers)

      cond do
        intent != [@intent] -> rejected(conn, 403, "api_intent_required")
        origin not in Enum.take(origins, 4) -> rejected(conn, 403, "api_origin_untrusted")
        path == "/api/eval" -> assert conn.status == 422
        true -> assert conn.status == 404
      end
    end

    request(:post, "/api/eval", "{}", [
      @intent,
      @json,
      {"origin", "http://localhost:4000"},
      {"origin", "http://localhost:4000"}
    ])
    |> rejected(403, "api_origin_untrusted")
  end

  test "input classification query duplicates collisions and bodyless rejection" do
    cases = [
      {"/api/eval?code=x&code=x", "{}", [@json], 400, "api_query_forbidden"},
      {"/api/eval", "code=x", [{"content-type", "application/x-www-form-urlencoded"}], 415,
       "api_json_required"},
      {"/api/eval", "{}", [{"content-type", "text/plain"}], 415, "api_json_required"},
      {"/api/eval", "[]", [@json], 400, "api_object_required"},
      {"/api/eval", "{\"code\":\"x\",\"code\":\"x\"}", [@json], 400, "api_duplicate_key"},
      {"/api/eval", "{\"nested\":{\"a\":1,\"a\":2}}", [@json], 400, "api_duplicate_key"},
      {"/api/users/a/say", "{\"name\":\"a\"}", [@json], 400, "api_path_key_collision"},
      {"/api/agents/a/stop", "{\"other\":1}", [@json], 400, "api_body_forbidden"},
      {"/api/agents/a/stop", " ", [@json], 400, "api_object_required"}
    ]

    for {path, body, headers, status, code} <- cases do
      request(:post, path, body, [@intent | headers]) |> rejected(status, code)
    end

    for path <- [
          "/api/agents/a/stop",
          "/api/agents/a/restart",
          "/api/agents/a/resume",
          "/api/agents/a/unhalt",
          "/api/users/a/inbox/consume"
        ] do
      for bytes <- ["", "{}"] do
        assert request(:post, path, bytes, [@intent, @json]).status == 404
      end
    end

    request(:delete, "/api/settings/no_such_setting", "{}", [@intent, @json])
    |> json_response(404)
  end

  test "method overrides refused before Head or parsers on every original method" do
    for method <- [:get, :head, :options, :post, :put, :patch, :delete],
        header <- ~w(x-http-method-override x-method-override x-http-method) do
      request(method, "/api/eval", "", [{header, ""}])
      |> rejected(400, "api_method_override_forbidden")
    end

    for method <- [:get, :head, :options, :post],
        {path, bytes, headers} <- [
          {"/api/eval?_method=", "", []},
          {"/api/eval", "{\"_method\":\"\"}", [@json]},
          {"/api/eval", "_method=", [{"content-type", "application/x-www-form-urlencoded"}]}
        ] do
      request(method, path, bytes, headers) |> rejected(400, "api_method_override_forbidden")
    end
  end

  test "rejected mutations preserve real agent inbox credential image and settings stores" do
    Nano.FakeOpenRouter.start()
    name = "guard_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(Nano.FakeOpenRouter.model()))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    user_name = "guard_user_#{System.unique_integer([:positive])}"
    user = Nano.User.start(user_name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, user) end)
    send(user, :retained)
    inbox = Nano.User.inbox(user_name)
    credentials = Nano.ChatGPT.Auth.status()
    settings = File.read!(Path.join(Application.fetch_env!(:nano, :state_dir), "settings.json"))
    images = Path.wildcard(Path.join(Application.fetch_env!(:nano, :image_dir), "**/*"))

    for path <- [
          "/api/agents/#{name}/stop",
          "/api/agents/#{name}/restart",
          "/api/agents/#{name}/resume",
          "/api/agents/#{name}/unhalt",
          "/api/users/#{user_name}/inbox/consume",
          "/api/chatgpt/login",
          "/api/chatgpt/logout",
          "/api/images"
        ] do
      request(:post, path, "{}", [@json]) |> rejected(403, "api_intent_required")
    end

    assert NanoAgent.whereis(name) == pid
    assert Nano.ChatGPT.Auth.status() == credentials

    assert File.read!(Path.join(Application.fetch_env!(:nano, :state_dir), "settings.json")) ==
             settings

    assert Path.wildcard(Path.join(Application.fetch_env!(:nano, :image_dir), "**/*")) == images

    for method <- [:get, :head] do
      assert request(method, "/api/users/#{user_name}/inbox?clear=true").status == 400
      assert Nano.User.inbox(user_name) == inbox
    end

    assert request(:get, "/api/users/#{user_name}/inbox").status == 200
    assert Nano.User.inbox(user_name) == inbox
    assert request(:post, "/api/users/#{user_name}/inbox/consume", "", [@intent]).status == 200
    assert Nano.User.inbox(user_name) == []
  end

  test "configured proxy origins and normalized HTTPS/default ports ignore request Host" do
    saved =
      for key <- [:api_public_port, :api_trusted_origins],
          do: {key, Application.fetch_env!(:nano, key)}

    on_exit(fn -> for {k, v} <- saved, do: Application.put_env(:nano, k, v) end)
    Application.put_env(:nano, :api_public_port, 8443)

    Application.put_env(:nano, :api_trusted_origins, [
      "https://proxy.example:443",
      "http://localhost:8123"
    ])

    for origin <- ["https://PROXY.example", "http://localhost:8123"] do
      assert request(:post, "/api/eval", "{}", [
               @intent,
               @json,
               {"origin", origin},
               {"host", "evil.example"},
               {"forwarded", "host=evil.example;proto=http"}
             ]).status == 422
    end

    request(:post, "/api/eval", "{}", [@intent, @json, {"origin", "http://localhost:4000"}])
    |> rejected(403, "api_origin_untrusted")

    Application.put_env(:nano, :api_trusted_origins, ["not an origin"])
    request(:post, "/api/eval?_method=", "", []) |> rejected(503, "api_policy_unavailable")
    assert request(:get, "/api").status == 200
  end

  test "push-settings actual script succeeds with intent and refuses missing intent without value disclosure" do
    {:ok, server} = Bandit.start_link(plug: NanoWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"

    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "cli-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    file = Path.join(dir, "dummy.env")
    value = "nonsecret-dummy-value"
    File.write!(file, "U01_DUMMY=#{value}\n")
    {:ok, result} = Nano.Tools.sh("bin/push-settings '#{url}' '#{file}'")
    assert result.exit_code == 0
    refute result.text =~ value
    assert Nano.Settings.get("U01_DUMMY") == value
    :ok = Nano.Settings.delete("U01_DUMMY")
    negative = Path.join(dir, "missing-intent.sh")

    File.write!(
      negative,
      File.read!("bin/push-settings") |> String.replace("-H 'X-Nano-API-Intent: mutate' ", "")
    )

    {:ok, result} = Nano.Tools.sh("sh '#{negative}' '#{url}' '#{file}'")
    assert result.exit_code == 1
    assert result.text =~ "api_intent_required"
    refute result.text =~ value
    assert Nano.Settings.get("U01_DUMMY") == nil
  end

  test "disposable browser same-origin fetch carries intent through actual Endpoint" do
    {:ok, server} = Bandit.start_link(plug: NanoWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    saved = Application.fetch_env!(:nano, :api_trusted_origins)
    Application.put_env(:nano, :api_trusted_origins, ["http://127.0.0.1:#{port}"])
    on_exit(fn -> Application.put_env(:nano, :api_trusted_origins, saved) end)
    dir = Application.fetch_env!(:nano, :test_dir)
    File.mkdir_p!(dir)
    script = Path.join(dir, "browser.js")

    File.write!(
      script,
      "document.addEventListener('DOMContentLoaded', async () => { const r = await fetch('/api/settings/U01_BROWSER', {method:'PUT',headers:{'Content-Type':'application/json','X-Nano-API-Intent':'mutate'},body:JSON.stringify({value:'dummy'})}); document.body.setAttribute('data-u01-result', String(r.status)); });"
    )

    {:ok, result} =
      Nano.Tools.sh(
        "/usr/local/bin/lightpanda fetch 'http://127.0.0.1:#{port}/' --inject-script-file '#{script}' --wait-until done --wait-ms 2000 --dump html --dump-selector body",
        timeout: 10000,
        max_bytes: 1000
      )

    assert result.exit_code == 0
    assert Nano.Settings.get("U01_BROWSER") == "dummy"
    :ok = Nano.Settings.delete("U01_BROWSER")
  end

  test "all payload routes reject bodies independently of controller effects and pin error priority" do
    code = "send(:erlang.list_to_pid(#{inspect(:erlang.pid_to_list(self()))}), :guard_executed)"

    for path <- [
          "/api/agents",
          "/api/users",
          "/api/users/a/say",
          "/api/users/a/send_raw",
          "/api/eval",
          "/api/images"
        ],
        body <- [Jason.encode!(%{code: code, term: code}), "{}"] do
      request(:post, path <> "?same=value", body, [@intent, @json])
      |> rejected(400, "api_query_forbidden")

      refute_received :guard_executed
    end

    request(:put, "/api/settings/X", "{\"key\":\"X\"}", [@intent, @json])
    |> rejected(400, "api_path_key_collision")

    request(:post, "/api/eval", "{\"code\":1,\"co\\u0064e\":1}", [@intent, @json])
    |> rejected(400, "api_duplicate_key")

    for method <- [:put, :patch, :delete, :trace] do
      request(method, "/api/unknown", "{}", [@json]) |> rejected(403, "api_intent_required")
    end

    # The positive control proves the sentinel is valid source and reaches real Nano.Ops.eval.
    assert request(:post, "/api/eval", Jason.encode!(%{code: code}), [
             @intent,
             @json,
             {"origin", "http://localhost:4000"}
           ]).status == 200

    assert_received :guard_executed
  end

  test "malformed deployment policies fail closed, empty origin policy permits only deliberate no-Origin CLI" do
    keys = [:api_trusted_origins, :api_public_port]
    saved = for key <- keys, do: {key, Application.fetch_env!(:nano, key)}
    on_exit(fn -> for {k, v} <- saved, do: Application.put_env(:nano, k, v) end)

    for bad <- [
          :invalid,
          ["null"],
          ["http://user@localhost:4000"],
          ["http://localhost:4000/path"],
          ["http://localhost:4000?x"],
          ["http://localhost:4000#x"],
          ["http://local%host:4000"],
          ["http://localhost:0"]
        ] do
      Application.put_env(:nano, :api_trusted_origins, bad)

      request(:post, "/api/eval", "{}", [@intent, @json])
      |> rejected(503, "api_policy_unavailable")
    end

    Application.put_env(:nano, :api_trusted_origins, [])
    assert request(:post, "/api/eval", "{}", [@intent, @json]).status == 422

    request(:post, "/api/eval", "{}", [@intent, @json, {"origin", "http://localhost:4000"}])
    |> rejected(403, "api_origin_untrusted")

    Application.put_env(:nano, :api_public_port, :invalid)
    request(:post, "/api/eval", "{}", [@intent, @json]) |> rejected(503, "api_policy_unavailable")
  end

  test "Cartesian intent origin body original-method matrix has no unintended eval effect" do
    code = "send(:erlang.list_to_pid(#{inspect(:erlang.pid_to_list(self()))}), :matrix_executed)"
    json = Jason.encode!(%{code: code})
    query = "?" <> URI.encode_query(%{code: code})

    origins = [
      {[], true},
      {[{"origin", "http://localhost:4000"}], true},
      {[{"origin", "https://evil.example"}], false},
      {[{"origin", "null"}], false},
      {[{"origin", "malformed"}], false},
      {[{"origin", "http://localhost:4000"}, {"origin", "http://localhost:4000"}], false}
    ]

    bodies = [
      {json, [@json], "", 200, nil},
      {URI.encode_query(%{code: code}), [{"content-type", "application/x-www-form-urlencoded"}],
       "", 415, "api_json_required"},
      {json, [{"content-type", "text/plain"}], "", 415, "api_json_required"},
      {"", [], query, 400, "api_query_forbidden"},
      {json, [@json], query, 400, "api_query_forbidden"},
      {"{\"code\":1,\"code\":2}", [@json], "", 400, "api_duplicate_key"},
      {"[]", [@json], "", 400, "api_object_required"}
    ]

    for {origin_headers, trusted} <- origins,
        intent <- [[], [@intent], [@intent, @intent], [{"x-nano-api-intent", "other"}]],
        {body, content, query, status, error} <- bodies,
        method <- [:post, :put, :patch, :delete, :get, :head, :options] do
      conn = request(method, "/api/eval" <> query, body, intent ++ origin_headers ++ content)

      cond do
        method in [:get, :head, :options] -> assert conn.status == 404
        intent != [@intent] -> rejected(conn, 403, "api_intent_required")
        not trusted -> rejected(conn, 403, "api_origin_untrusted")
        error -> rejected(conn, status, error)
        method != :post -> assert conn.status == 404
        true -> assert conn.status == 200
      end

      if method == :post and intent == [@intent] and trusted and error == nil,
        do: assert_received(:matrix_executed),
        else: refute_received(:matrix_executed)
    end
  end
end
