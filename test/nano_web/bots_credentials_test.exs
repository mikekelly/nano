defmodule NanoWeb.BotsCredentialsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  import ExUnit.CaptureLog
  @endpoint NanoWeb.Endpoint
  alias Vega.Bots
  alias Nano.FakeOpenRouter, as: Fake
  defp wait(fun, n \\ 200)
  defp wait(_, 0), do: flunk("credential requester did not converge")

  defp wait(fun, n),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(10)
            wait(fun, n - 1)
          )
      )

  setup do
    root = Path.join(System.tmp_dir!(), "bots-credential-" <> Vega.Store.id())

    {:ok, service} =
      start_supervised({Vega.Bots.Server, name: :bots_credential_test, root: root, tick_ms: 20})

    old = Application.get_env(:nano, :bots_server)
    Application.put_env(:nano, :bots_server, service)
    key = "VEGA_BOTS_TEST_SECRET_" <> Integer.to_string(System.unique_integer([:positive]))

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :bots_server, old),
        else: Application.delete_env(:nano, :bots_server)

      Nano.Settings.delete(key)
      File.rm_rf(root)
    end)

    {:ok, bot} =
      Bots.create_bot("Muse",
        server: service,
        model: "test",
        reasoning: "off",
        max_context: 80000,
        max_turns: 0,
        max_tokens: 0
      )

    %{root: root, opts: [server: service], key: key, bot: bot}
  end

  test "allowed key names never authorize nonsecret settings or lowercase custom names", c do
    assert {:ok, "openrouter_api_key"} = Vega.Bots.Credentials.key("OPENROUTER_API_KEY")
    assert {:ok, key} = Vega.Bots.Credentials.key(c.key)
    assert key == c.key
    assert {:error, _} = Vega.Bots.Credentials.key("NODE_MAX_TOKENS_PER_HOUR")
    assert {:error, _} = Vega.Bots.Credentials.key("system_prompt_file")
    assert {:error, _} = Vega.Bots.Credentials.key("lowercase_custom")
    assert {:error, _} = Vega.Bots.Credentials.key("../PATH")

    assert {:error, _} =
             Bots.request_setting(
               c.bot["id"],
               "NODE_MAX_TOKENS_PER_HOUR",
               "Bad request",
               c.opts ++ [requester: "agent"]
             )
  end

  test "password JSON writes only settings, relays metadata and never chat/model/harness/debug logs",
       c do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    name = "credential-requester-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, max_turns: 10))

    on_exit(fn ->
      if live = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, live)
        NanoAgent.kill_tasks(live)
      end

      Nano.StateStore.delete(name)
    end)

    {:ok, r} =
      Bots.request_setting(
        c.bot["id"],
        c.key,
        "Enter the demo service credential in the password control, not chat",
        c.opts ++ [requester: name]
      )

    assert r["kind"] == "setting"
    fake_secret = "fake-password-ONLY-setting-store-a19b2c3d"
    assert {:error, :use_setting_form} = Bots.answer_request(r["id"], fake_secret, c.opts)
    Fake.push(model, calls: [idle: nil])
    page = get(build_conn(), "/bots")
    csrf = Regex.run(~r/name="csrf-token" content="([^"]+)"/, page.resp_body) |> List.last()

    conn =
      recycle(page)
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-csrf-token", csrf)

    logs =
      capture_log([level: :debug], fn ->
        response =
          post(
            conn,
            "/bots/requests/" <> r["id"] <> "/setting",
            Jason.encode!(%{password: fake_secret})
          )

        assert response.status == 200

        assert json_response(response, 200) == %{
                 "ok" => true,
                 "setting" => %{"setting_key" => c.key, "set" => true}
               }

        refute response.resp_body =~ fake_secret
        refute inspect(response.params) =~ fake_secret
      end)

    refute logs =~ fake_secret
    assert Nano.Settings.get(c.key) == fake_secret
    settings_path = Path.join(Application.fetch_env!(:nano, :state_dir), "settings.json")
    assert File.read!(settings_path) =~ fake_secret
    assert Bitwise.band(File.stat!(settings_path).mode, 0o777) == 0o600
    assert_receive {:openrouter_request, ^model, body}, 4000
    encoded = Jason.encode!(body)
    assert encoded =~ c.key
    assert encoded =~ "vega_human_answer"
    refute encoded =~ fake_secret
    wait(fn -> NanoAgent.info(name).status == :idle end)
    refute Jason.encode!(Nano.StateStore.get(name).transcript) =~ fake_secret
    refute Jason.encode!(Nano.Ops.log(name)) =~ fake_secret
    {:ok, updated} = Bots.get_request(r["id"], c.opts)
    assert updated["answer"] == %{"setting_key" => c.key, "set" => true}
    {:ok, chat} = Bots.get_session(r["session_id"], c.opts)
    refute Jason.encode!(chat) =~ fake_secret
    refute File.read!(Vega.Bots.Persistence.path(c.root)) =~ fake_secret
    assert {:ok, metadata} = Bots.answer_setting(r["id"], "ignored-new-fake-password", c.opts)
    assert metadata == updated["answer"]
    assert Nano.Settings.get(c.key) == fake_secret
    assert {:ok, _} = Bots.acknowledge_answer(r["id"], c.opts ++ [requester: name])
    assert Process.alive?(pid)
  end

  test "credential metadata survives restart and rejects unsafe persisted answers", c do
    {:ok, pending} =
      Bots.request_setting(
        c.bot["id"],
        c.key,
        "Credential",
        c.opts ++ [requester: "restart-requester"]
      )

    assert {:ok, _} = Bots.answer_setting(pending["id"], "fake-restart-value", c.opts)
    :ok = stop_supervised(Vega.Bots.Server)

    {:ok, service} =
      start_supervised({Vega.Bots.Server, name: :bots_credential_test, root: c.root, tick_ms: 20})

    assert {:ok, restored} = Bots.get_request(pending["id"], server: service)
    assert restored["answer"] == %{"setting_key" => c.key, "set" => true}
    assert {:ok, _} = Bots.answer_setting(pending["id"], "fake-ignored", server: service)
    assert Nano.Settings.get(c.key) == "fake-restart-value"
    {:ok, data} = Vega.Bots.Persistence.load(c.root)

    broken =
      Map.update!(data, "requests", fn requests ->
        Enum.map(requests, &Map.put(&1, "answer", "unsafe plaintext"))
      end)

    assert {:error, :invalid_or_oversized_store} = Vega.Bots.Persistence.save(c.root, broken)
  end

  test "password endpoint refuses JSON without CSRF and does not write settings", c do
    {:ok, request} =
      Bots.request_setting(
        c.bot["id"],
        c.key,
        "Credential",
        c.opts ++ [requester: "csrf-requester"]
      )

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      build_conn()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/bots/requests/" <> request["id"] <> "/setting",
        Jason.encode!(%{password: "fake-csrf-secret"})
      )
    end

    refute Nano.Settings.get(c.key)
    assert {:ok, pending} = Bots.get_request(request["id"], c.opts)
    assert pending["status"] == "pending"
  end
end
