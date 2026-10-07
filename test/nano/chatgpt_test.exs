defmodule Nano.ChatGPTTest do
  # Not async: the credentials process, its token file and the fake are node-wide.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nano.ChatGPT.Auth
  alias Nano.FakeChatGPT, as: Fake

  @endpoint NanoWeb.Endpoint

  setup do
    Fake.start()
    Fake.listen()
    :ok = Auth.logout()
    :persistent_term.erase({Nano.ChatGPT, :models})
    saved = Application.get_env(:nano, :openrouter_backoff_ms)
    Application.put_env(:nano, :openrouter_backoff_ms, 1)

    on_exit(fn ->
      Auth.logout()
      :persistent_term.erase({Nano.ChatGPT, :models})
      Application.put_env(:nano, :openrouter_backoff_ms, saved)
    end)
  end

  defp path, do: Path.join(Application.fetch_env!(:nano, :state_dir), "chatgpt_auth.json")
  defp saved, do: path() |> File.read!() |> Jason.decode!()

  defp eventually(fun, tries \\ 250) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # Connects through the device flow, approved at the first poll; returns the token response.
  defp connect!(tokens \\ Fake.tokens()) do
    # Clears answers queued earlier in the test.
    Fake.listen()
    Fake.auth(:poll, [{200, :approved}])
    Fake.auth(:token, [{200, tokens}])
    assert %{status: :pending} = Auth.login()
    eventually(fn -> Auth.status().status == :connected end)
    flush_auth()
    tokens
  end

  defp flush_auth do
    receive do
      {:chatgpt_auth, _, _} -> flush_auth()
    after
      0 -> :ok
    end
  end

  defp restart_auth do
    old = Process.whereis(Auth)
    Process.exit(old, :kill)
    eventually(fn -> (pid = Process.whereis(Auth)) && pid != old end)
  end

  ## Device-code login

  test "device flow: a code to enter, polling while pending, then tokens saved 0600" do
    Fake.auth(:poll, [{403, %{}}, {200, :approved}])
    tokens = Fake.tokens()
    Fake.auth(:token, [{200, tokens}])

    status = Auth.login()
    assert %{status: :pending, user_code: "FAKE-CODE"} = status
    assert status.verification_url =~ ~r"/codex/device$"
    assert DateTime.diff(status.expires_at, DateTime.utc_now()) in 890..900
    # A second login while one is pending shows the same code.
    assert Auth.login().user_code == "FAKE-CODE"

    assert_receive {:chatgpt_auth, :usercode, %{"client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"}}

    assert_receive {:chatgpt_auth, :poll,
                    %{"device_auth_id" => "dev-1", "user_code" => "FAKE-CODE"}}

    assert_receive {:chatgpt_auth, :poll, _}, 3_000
    assert_receive {:chatgpt_auth, :token, exchange}, 3_000

    assert %{
             "grant_type" => "authorization_code",
             "code" => "authcode",
             "code_verifier" => "verifier",
             "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"
           } = exchange

    assert exchange["redirect_uri"] =~ ~r"/deviceauth/callback$"

    eventually(fn -> Auth.status().status == :connected end)

    assert %{email: "me@example.com", plan: "plus", user_code: nil, error: nil} =
             Nano.Ops.chatgpt()

    # Saved where only the owner can read it, and never shown.
    assert File.stat!(path()).mode |> Bitwise.band(0o777) == 0o600
    assert saved()["refresh_token"] == tokens["refresh_token"]
    assert saved()["account_id"] == "acct-fake"
    refute inspect(Auth.status()) =~ tokens["access_token"]
    refute inspect(Auth.status()) =~ tokens["refresh_token"]
    # Nor in what a crash report or :sys.get_status prints of the process.
    refute inspect(:sys.get_status(Auth)) =~ tokens["refresh_token"]

    assert {:ok, %{access_token: access, account_id: "acct-fake"}} = Auth.token()
    assert access == tokens["access_token"]
  end

  test "device flow: a refused or expired code ends the login, not connected" do
    Fake.auth(:poll, [{400, %{"error" => %{"code" => "access_denied"}}}])
    assert %{status: :pending} = Auth.login()
    eventually(fn -> Auth.status().status == :disconnected end)
    assert Auth.status().error =~ "refused: HTTP 400: access_denied"

    # Expiry: the deadline is 15 minutes away, so move it into the past.
    assert %{status: :pending} = Auth.login()
    assert_receive {:chatgpt_auth, :poll, _}
    :sys.replace_state(Auth, &put_in(&1.login.expires_at, 0))
    send(Auth, {:poll, :sys.get_state(Auth).login.ref})
    eventually(fn -> Auth.status().status == :disconnected end)
    assert Auth.status().error =~ "expired"
    assert {:error, _} = Auth.token()
  end

  test "a login code that cannot be had is an error for the caller" do
    Fake.auth(:usercode, [{404, %{}}])
    assert {:error, message} = Nano.Ops.chatgpt_login()
    assert message =~ "device-code login"
    assert Auth.status().status == :disconnected
  end

  ## Restarts

  test "credentials survive a restart of their process; a login in progress does not" do
    tokens = connect!()
    restart_auth()
    assert %{status: :connected, email: "me@example.com"} = Auth.status()
    assert {:ok, %{access_token: access}} = Auth.token()
    assert access == tokens["access_token"]
    refute_received {:chatgpt_auth, :usercode, _}

    # Interrupted mid-login: back as it was before the login, and a new login works.
    :ok = Auth.logout()
    Fake.auth(:poll, List.duplicate({403, %{}}, 5))
    assert %{status: :pending} = Auth.login()
    restart_auth()
    assert %{status: :disconnected, user_code: nil} = Auth.status()
    assert {:error, _} = Auth.token()
    connect!()
  end

  test "an unreadable token file comes up not connected" do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), "{not json")

    ExUnit.CaptureLog.capture_log(fn -> restart_auth() end)
    assert Auth.status().status == :disconnected
  end

  ## Refresh

  test "a token near expiry is refreshed first, the rotated refresh token saved" do
    first = connect!(Fake.tokens(expires_in: 100))
    second = Fake.tokens()
    third = Fake.tokens()
    Fake.auth(:token, [{200, second}])

    assert {:ok, %{access_token: access}} = Auth.token()
    assert access == second["access_token"]
    assert_receive {:chatgpt_auth, :token, refresh}

    assert refresh == %{
             "grant_type" => "refresh_token",
             "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
             "refresh_token" => first["refresh_token"]
           }

    assert saved()["refresh_token"] == second["refresh_token"]

    # A 401 from the backend forces one refresh, with the latest refresh token; a caller whose
    # token is already stale gets the new one without another refresh.
    Fake.auth(:token, [{200, third}])
    assert {:ok, %{access_token: new}} = Auth.refresh(second["access_token"])
    assert new == third["access_token"]
    assert_receive {:chatgpt_auth, :token, %{"refresh_token" => rt}}
    assert rt == second["refresh_token"]
    assert {:ok, %{access_token: ^new}} = Auth.refresh(second["access_token"])
    refute_receive {:chatgpt_auth, :token, _}, 50
  end

  test "a refused refresh signs out; a failed one keeps the tokens while they last" do
    tokens = connect!(Fake.tokens(expires_in: 100))
    Fake.auth(:token, [{503, %{}}])
    log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{access_token: _}} = Auth.token() end)
    assert log =~ "refresh failed: HTTP 503"
    refute log =~ tokens["refresh_token"]
    assert Auth.status().status == :connected
    assert Auth.status().error =~ "could not refresh"

    Fake.auth(:token, [{400, %{"error" => %{"code" => "refresh_token_reused"}}}])
    ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = Auth.token() end)
    assert %{status: :disconnected, error: error} = Auth.status()
    assert error =~ "refresh_token_reused"
    refute File.exists?(path())
  end

  ## Inference

  defp start_agent!(opts \\ []) do
    model = Fake.model()
    name = "c#{System.unique_integer([:positive])}"
    opts = Nano.FakeOpenRouter.opts("openai-codex/" <> model, [max_context: 272_000] ++ opts)
    {:ok, _} = NanoAgent.start([name: name] ++ opts)

    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    id = NanoAgent.info(name).id
    Nano.Log.subscribe(id)
    {model, name, id}
  end

  defp request!(model) do
    assert_receive {:chatgpt_request, ^model, body, headers}, 3_000
    {body, Map.new(headers)}
  end

  defp entries(id, type), do: for(e <- Nano.Log.read(id), e["type"] == type, do: e)

  defp await(id, type, n \\ 1) do
    eventually(fn -> length(entries(id, type)) >= n end)
    Enum.at(entries(id, type), n - 1)
  end

  test "agents on openai-codex/ need a connected subscription" do
    assert {:error, "the ChatGPT subscription is not connected: connect it from the " <> _} =
             NanoAgent.start([name: "nc"] ++ Nano.FakeOpenRouter.opts("openai-codex/gpt-5.5"))
  end

  test "agents on openai-codex/ are checked against the subscription's models" do
    connect!()
    model = "openai-codex/" <> Fake.model()
    opts = Nano.FakeOpenRouter.opts(model, max_context: 272_000)
    start = &NanoAgent.start([name: "nc"] ++ Keyword.merge(opts, &1))

    assert {:error,
            "unknown model openai-codex/gpt-none: the ChatGPT subscription offers " <> ids} =
             start.(model: "openai-codex/gpt-none")

    assert model in String.split(ids, ", ")

    assert start.(max_context: 272_001) ==
             {:error,
              "max_context must be a whole number of tokens from 1 to 272000, #{model}'s " <>
                "context window (there is no unlimited context), not 272001"}

    assert start.(reasoning: "ultra") ==
             {:error,
              ~s(reasoning "ultra" is not supported by #{model}; supported: off, minimal, ) <>
                "low, medium, high, xhigh, max"}
  end

  test "image references become Responses input_image only at the request edge" do
    connect!()
    model = Fake.model()
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 1::32, 1::32, 8, 2, 0, 0, 0>>
    {:ok, ref} = Vega.Images.import_bytes(bytes)

    messages = [
      %{"role" => "system", "content" => "see"},
      %{"role" => "user", "content" => Vega.Images.content("look", [ref])}
    ]

    Fake.push(model, text: "seen")
    assert {:ok, _} = Nano.ChatGPT.chat(model, messages, [], "low")
    {body, _} = request!(model)

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text"},
                 %{"type" => "input_image", "image_url" => url}
               ]
             }
           ] = body["input"]

    assert url == "data:image/png;base64," <> Base.encode64(bytes)
    refute Jason.encode!(messages) =~ "data:image"
  end

  test "no bound on the response is sent: the backend refuses max_output_tokens" do
    connect!()
    {model, name, _} = start_agent!(max_context: 10_000)
    Fake.push(model, text: "ok")
    NanoAgent.notify(name, :hi)
    {body, _} = request!(model)
    refute Map.has_key?(body, "max_output_tokens")
    refute Map.has_key?(body, "max_tokens")
  end

  test "a conversation round-trips: tools, calls, results, reasoning items, usage" do
    tokens = connect!()
    {model, name, id} = start_agent!()

    Fake.push(model, calls: [eval: "1 + 1"], reasoning: "add them", usage: {1000, 50, 0})
    Fake.push(model, text: "done", usage: {1200, 20, 1000})
    NanoAgent.notify(name, :hi)

    {first, headers} = request!(model)
    assert headers["authorization"] == "Bearer " <> tokens["access_token"]
    assert headers["chatgpt-account-id"] == "acct-fake"
    assert headers["accept"] == "text/event-stream"
    assert headers["session-id"] == first["prompt_cache_key"]

    assert %{
             "store" => false,
             "stream" => true,
             "include" => ["reasoning.encrypted_content"],
             "tool_choice" => "auto",
             "reasoning" => %{"effort" => "none"},
             "model" => ^model
           } = first

    assert first["instructions"] == NanoAgent.info(name).system_prompt

    assert [%{"type" => "function", "name" => "eval", "parameters" => _}, %{"name" => "idle"}] =
             first["tools"]

    assert [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text"}]}] =
             first["input"]

    {second, _} = request!(model)
    assert second["prompt_cache_key"] == first["prompt_cache_key"]

    assert [
             _user,
             %{"type" => "reasoning", "encrypted_content" => "enc-" <> _, "summary" => [_]},
             %{
               "type" => "function_call",
               "name" => "eval",
               "call_id" => call,
               "arguments" => args
             },
             %{"type" => "function_call_output", "call_id" => call, "output" => "2"}
           ] = second["input"]

    assert Jason.decode!(args) == %{"code" => "1 + 1"}

    ended = await(id, "turn_ended")
    assert ended["reason"] == "no_tool_call"
    [r1, r2] = entries(id, "model_response")
    assert %{"provider" => "ChatGPT", "reasoning" => "add them", "prompt_tokens" => 1000} = r1
    assert %{"text" => "done", "cached_tokens" => 1000, "completion_tokens" => 20} = r2
    assert r1["finish_reason"] == "tool_calls" and r2["finish_reason"] == "stop"

    info = NanoAgent.info(name)
    assert info.budget.tokens_used == 1050 + 1220
    assert info.budget.turns_used == 2
    assert info.budget.context_used == 1220
    assert info.cache_hit_rate == 0.5

    # The next delivery's budget line counts it.
    Fake.push(model, text: "ok")
    NanoAgent.notify(name, :again)
    {third, _} = request!(model)
    last = List.last(third["input"])["content"] |> hd() |> Map.fetch!("text")
    assert last =~ "Used so far: 2 of 500 turns, 2270 of"

    # No token in the log.
    log = File.read!(Path.join(Application.fetch_env!(:nano, :log_dir), id <> ".jsonl"))
    refute log =~ tokens["access_token"]
    refute log =~ tokens["refresh_token"]
  end

  test "reasoning levels map to the backend's efforts" do
    connect!()

    for {level, effort} <- [{"minimal", "low"}, {"high", "high"}, {"max", "max"}] do
      {model, name, _} = start_agent!(reasoning: level)
      Fake.push(model, text: "ok")
      NanoAgent.notify(name, :hi)
      {body, _} = request!(model)
      assert body["reasoning"] == %{"effort" => effort, "summary" => "auto"}
    end
  end

  test "a usage limit halts the agent without retrying; un-halting resumes it" do
    connect!()
    {model, name, id} = start_agent!()

    resets = System.system_time(:second) + 3600

    Fake.push(model,
      status: 429,
      body: %{
        "error" => %{
          "type" => "usage_limit_reached",
          "plan_type" => "plus",
          "resets_at" => resets
        }
      }
    )

    NanoAgent.notify(name, :hi)
    request!(model)
    error = await(id, "model_error")
    assert %{"status" => 429, "retry" => false} = error
    eventually(fn -> NanoAgent.info(name).halted == :usage_limit end)
    refute_receive {:chatgpt_request, ^model, _, _}, 100

    note = List.last(entries(id, "harness_note"))["text"]

    assert note =~
             "The ChatGPT plan (plus) this node uses for you has reached its usage limit until"

    assert note =~ "so I have halted you"

    # Halted: events queue. Un-halted: they are delivered with the note.
    NanoAgent.notify(name, :queued)
    refute_receive {:chatgpt_request, ^model, _, _}, 100
    Fake.push(model, text: "back")
    Nano.Ops.unhalt(name)
    {body, _} = request!(model)
    assert List.last(body["input"])["content"] |> hd() |> Map.fetch!("text") =~ ":queued"
  end

  test "server errors and other rate limits are retried; a 401 refreshes the token once" do
    connect!()
    {model, name, id} = start_agent!()
    Fake.push(model, status: 500)
    Fake.push(model, status: 429, body: %{"error" => %{"type" => "rate_limit_exceeded"}})
    Fake.push(model, failed: %{"code" => "server_is_overloaded", "message" => "busy"})
    NanoAgent.notify(name, :hi)
    for _ <- 1..3, do: request!(model)
    await(id, "model_error", 3)
    assert Enum.map(entries(id, "model_error"), & &1["retry"]) == [true, true, false]

    fresh = Fake.tokens()
    Fake.auth(:token, [{200, fresh}])
    Fake.push(model, status: 401)
    Fake.push(model, text: "ok")
    NanoAgent.notify(name, :again)
    request!(model)
    {_, headers} = request!(model)
    assert headers["authorization"] == "Bearer " <> fresh["access_token"]
    assert_receive {:chatgpt_auth, :token, %{"grant_type" => "refresh_token"}}
    assert await(id, "model_response")["text"] == "ok"
  end

  test "models: the backend's list when it answers, else the known list" do
    assert Nano.ChatGPT.models() == []
    connect!()

    # Levels as the backend lists them (2026-10-07): "none" is "off", and "ultra" has no level.
    efforts = &for(e <- &1, do: %{"effort" => e, "description" => "#{e} reasoning"})

    Fake.models([
      %{
        "slug" => "gpt-x",
        "display_name" => "GPT-X",
        "context_window" => 1000,
        "supported_reasoning_levels" => efforts.(~w(low medium high xhigh max ultra)),
        "default_reasoning_level" => "low"
      },
      %{
        "slug" => "gpt-y",
        "supported_reasoning_levels" => efforts.(~w(none low medium)),
        "default_reasoning_level" => "none"
      },
      %{"slug" => "hidden", "visibility" => "hide"}
    ])

    assert Nano.ChatGPT.models() == [
             %{
               id: "gpt-x",
               name: "GPT-X",
               input_modalities: ["text"],
               context_length: 1000,
               reasoning_levels: ~w(low medium high xhigh max),
               default_reasoning: "low"
             },
             %{
               id: "gpt-y",
               name: "gpt-y",
               input_modalities: ["text"],
               context_length: nil,
               reasoning_levels: ~w(off low medium),
               default_reasoning: "off"
             }
           ]

    # In the catalog's priority order, lowest first.
    :persistent_term.erase({Nano.ChatGPT, :models})

    Fake.models([
      %{"slug" => "gpt-b", "priority" => 2},
      %{"slug" => "gpt-a", "priority" => 1}
    ])

    assert [%{id: "gpt-a"}, %{id: "gpt-b"}] = Nano.ChatGPT.models()

    :persistent_term.erase({Nano.ChatGPT, :models})
    Fake.models(500)

    assert %{id: "gpt-6.1-sol", context_length: 272_000, default_reasoning: "low"} =
             hd(Nano.ChatGPT.models())

    assert hd(Nano.ChatGPT.models()).reasoning_levels == ~w(low medium high xhigh max)
  end

  ## Operator surfaces

  # The levels the start form's reasoning select offers.
  defp levels(view) do
    html = view |> element("#start select[name=reasoning]") |> render()
    for [_, level] <- Regex.scan(~r/<option[^>]*value="([^"]+)"/, html), do: level
  end

  test "the API: status, login and logout, never the tokens" do
    tokens = Fake.tokens()
    Fake.auth(:poll, List.duplicate({403, %{}}, 3))

    assert %{"status" => "disconnected"} =
             build_conn() |> get("/api/chatgpt") |> json_response(200)

    assert %{"status" => "pending", "user_code" => "FAKE-CODE", "verification_url" => url} =
             build_conn() |> post("/api/chatgpt/login") |> json_response(200)

    assert url =~ "/codex/device"
    assert %{"ok" => true} = build_conn() |> post("/api/chatgpt/logout") |> json_response(200)

    connect!(tokens)
    body = build_conn() |> get("/api/chatgpt") |> json_response(200)
    assert %{"status" => "connected", "plan" => "plus", "email" => "me@example.com"} = body
    refute Jason.encode!(body) =~ tokens["access_token"]

    index = build_conn() |> get("/api") |> json_response(200)
    assert Enum.any?(index["endpoints"], &(&1["path"] == "/api/chatgpt/login"))

    Fake.auth(:usercode, [{500, %{}}])
    :ok = Auth.logout()
    assert %{"error" => _} = build_conn() |> post("/api/chatgpt/login") |> json_response(502)
  end

  test "the dashboard: with ChatGPT chosen, connect shows the code and link, then who is connected" do
    Fake.auth(:poll, List.duplicate({403, %{}}, 3))
    {:ok, view, html} = live(build_conn(), "/")
    # OpenRouter is the default provider here, and the subscription is not mentioned.
    refute html =~ "Connect ChatGPT"
    refute has_element?(view, "#chatgpt")

    view |> form("#start", %{provider: "chatgpt"}) |> render_change(%{_target: ["provider"]})
    assert has_element?(view, "#chatgpt", "not connected")
    assert has_element?(view, "#start button.primary[disabled]")
    assert has_element?(view, "#start .actions", "connect the ChatGPT subscription first")
    # No models to offer yet, so no default either.
    assert has_element?(view, "#start input[name=model][value='']")

    html = view |> element("#chatgpt button", "Connect ChatGPT") |> render_click()
    assert html =~ "FAKE-CODE"
    assert html =~ "/codex/device"

    view |> element("#chatgpt button", "cancel") |> render_click()
    view |> form("#start", %{name: "typing"}) |> render_change()

    levels = for e <- ~w(low medium high xhigh max ultra), do: %{"effort" => e}

    Fake.models([
      %{
        "slug" => "gpt-6-luna",
        "display_name" => "GPT-6 Luna",
        "priority" => 4,
        "supported_reasoning_levels" => levels,
        "default_reasoning_level" => "medium",
        "context_window" => 128_000
      },
      %{
        "slug" => "gpt-6.1-sol",
        "display_name" => "GPT-6.1 Sol",
        "priority" => 1,
        "supported_reasoning_levels" => levels,
        "default_reasoning_level" => "low",
        "context_window" => 272_000,
        "max_context_window" => 872_000
      }
    ])

    connect!()
    send(view.pid, :refresh)
    assert has_element?(view, "#chatgpt", "connected as me@example.com (plus)")
    refute has_element?(view, "#start button.primary[disabled]")
    # The box left blank gets the subscription's first model, shown without its prefix, and
    # the reasoning select only that model's levels, set to its default; max context is its
    # context window, and turns and tokens are 0, no limit.
    assert has_element?(view, "#start input[name=model][value='gpt-6.1-sol']")
    assert levels(view) == ~w(low medium high xhigh max)
    assert has_element?(view, "#start option[selected][value=low]")
    assert has_element?(view, "#start input[name=max_context][value='272000']")
    assert has_element?(view, "#start input[name=max_turns][value='0']")
    assert has_element?(view, "#start input[name=max_tokens][value='0']")

    # Only the subscription's models are offered, by name.
    view |> form("#start", %{model: "luna"}) |> render_change(%{_target: ["model"]})
    assert has_element?(view, "#start .matches button .id", ~r/^gpt-6-luna$/)

    # Choosing a model sets its default; a level chosen for it is kept until the model changes.
    view |> element("#start .matches button", "gpt-6-luna") |> render_click()
    assert has_element?(view, "#start option[selected][value=medium]")
    view |> form("#start", %{reasoning: "max"}) |> render_change(%{_target: ["reasoning"]})
    view |> form("#start", %{name: "typing"}) |> render_change(%{_target: ["name"]})
    send(view.pid, :refresh)
    assert has_element?(view, "#start option[selected][value=max]")

    # It is sent as an openai-codex/ slug, with the level chosen.
    Fake.listen()
    name = "codex_#{System.unique_integer([:positive])}"
    on_exit(fn -> Nano.Ops.stop_agent(name) end)

    assert {:error, {:live_redirect, _}} =
             view |> form("#start", %{name: name, model: "gpt-6-luna"}) |> render_submit()

    assert %{
             model: "openai-codex/gpt-6-luna",
             reasoning: "max",
             context_window: 128_000,
             budget: %{max_context: 128_000, max_turns: 0, max_tokens: 0}
           } = Nano.Ops.agent(name)

    # Back to OpenRouter: no model chosen, and nothing about the subscription.
    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#start", %{provider: "chatgpt"}) |> render_change(%{_target: ["provider"]})
    view |> form("#start", %{provider: "openrouter"}) |> render_change(%{_target: ["provider"]})
    assert has_element?(view, "#start input[name=model][value='']")
    refute has_element?(view, "#chatgpt")
  end

  test "the start form: each provider's own models; a whole slug of the other chooses it" do
    Nano.FakeOpenRouter.start()
    Nano.FakeOpenRouter.models([%{"id" => "openai/gpt-5.5", "name" => "OpenAI: GPT-5.5"}])
    :persistent_term.erase({Nano.OpenRouter, :models})
    on_exit(fn -> :persistent_term.erase({Nano.OpenRouter, :models}) end)
    Fake.models([%{"slug" => "gpt-5.5", "display_name" => "GPT-5.5"}])
    connect!()
    {:ok, view, _} = live(build_conn(), "/")

    # Connected, the subscription's models are still not offered under OpenRouter, and
    # OpenRouter's are not offered under ChatGPT.
    view |> form("#start", %{model: "gpt-5"}) |> render_change()
    assert has_element?(view, "#start .matches button .id", ~r/^openai\/gpt-5\.5$/)
    refute has_element?(view, "#start .matches button .id", ~r/^(openai-codex\/)?gpt-5\.5$/)
    view |> form("#start", %{provider: "chatgpt"}) |> render_change(%{_target: ["provider"]})
    view |> form("#start", %{model: "gpt-5"}) |> render_change()
    assert has_element?(view, "#start .matches button .id", ~r/^gpt-5\.5$/)
    refute has_element?(view, "#start .matches button .id", "/")

    view |> form("#start", %{provider: "openrouter"}) |> render_change(%{_target: ["provider"]})

    view |> form("#start", %{model: "openai-codex/gpt-5.5"}) |> render_change()
    assert has_element?(view, "#start .segmented label.on", "ChatGPT")
    assert has_element?(view, "#chatgpt", "connected")

    # An OpenRouter slug typed under ChatGPT goes back to OpenRouter.
    view |> form("#start", %{model: "anthropic/claude-haiku-4.5"}) |> render_change()
    assert has_element?(view, "#start .segmented label.on", "OpenRouter")
    refute has_element?(view, "#chatgpt")

    # Submitted without a change event, the slug is sent as it is.
    opts = &NanoWeb.StartForm.opts(%{"provider" => &1, "model" => &2})
    assert opts.("openrouter", "openai-codex/gpt-5.5")[:model] == "openai-codex/gpt-5.5"
    assert opts.("chatgpt", "openai-codex/gpt-5.5")[:model] == "openai-codex/gpt-5.5"
    assert opts.("chatgpt", "gpt-5.5")[:model] == "openai-codex/gpt-5.5"
    assert opts.("openrouter", "a/b")[:model] == "a/b"
    # Blank is no model, which the start refuses.
    assert opts.("chatgpt", " ")[:model] == nil
    assert opts.("openrouter", "")[:model] == nil
  end

  test "a node without an OpenRouter key: the subscription is the only provider" do
    Nano.TestSettings.delete(:openrouter_api_key)

    refused =
      "OpenRouter is off on this node (it has no OpenRouter API key); use an " <>
        "openai-codex/ model on the ChatGPT subscription, or set the openrouter_api_key " <>
        "setting (dashboard Settings, or PUT /api/settings/openrouter_api_key)"

    assert %{"providers" => %{"openrouter" => false, "chatgpt" => "disconnected"}} =
             build_conn() |> get("/api") |> json_response(200)

    # Neither provider: the form says so, over the subscription's connect control.
    {:ok, view, _} = live(build_conn(), "/")
    refute has_element?(view, "#start input[name=provider][value=openrouter]")
    assert has_element?(view, "#start .segmented label.on", "ChatGPT")
    assert has_element?(view, "#chatgpt button", "Connect ChatGPT")
    assert has_element?(view, "#start button.primary[disabled]")
    assert has_element?(view, "#start .actions", "no provider is on")

    # The API refuses an OpenRouter model, saying what to do.
    body = %{
      name: "or_#{System.unique_integer([:positive])}",
      model: "deepseek/deepseek-v4.1-flash",
      reasoning: "off",
      max_turns: 0,
      max_tokens: 0,
      max_context: 1000
    }

    assert %{"error" => "could not start agent: " <> ^refused} =
             build_conn()
             |> Plug.Conn.put_req_header("content-type", "application/json")
             |> post("/api/agents", Jason.encode!(body))
             |> json_response(422)

    # Only the subscription, connected: its models, and no OpenRouter option or notice.
    Fake.models([%{"slug" => "gpt-5.5", "display_name" => "GPT-5.5"}])
    connect!()
    send(view.pid, :refresh)
    refute has_element?(view, "#start input[name=provider][value=openrouter]")
    refute has_element?(view, "#start .actions", "no provider is on")
    assert has_element?(view, "#start input[name=model][value='gpt-5.5']")

    # An OpenRouter slug typed in the box is refused, not offered.
    view |> form("#start", %{model: "deepseek/deepseek-v4.1-flash"}) |> render_change()
    assert has_element?(view, "#start .segmented label.on", "ChatGPT")
    view |> form("#start", %{name: body.name}) |> render_submit()
    assert has_element?(view, "#start .error", refused)
  end
end
