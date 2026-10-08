defmodule Nano.RawLogTest do
  # Not async: raw_model_log and its cap are node-wide settings, the ChatGPT subscription is
  # node-wide, and each test starts from an empty raw directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias Nano.{FakeChatGPT, FakeOpenRouter, RawLog, TestSettings}

  @endpoint NanoWeb.Endpoint

  setup do
    FakeOpenRouter.start()
    File.rm_rf!(RawLog.dir())
    saved = Application.get_env(:nano, :openrouter_backoff_ms)
    Application.put_env(:nano, :openrouter_backoff_ms, 1)
    on_exit(fn -> Application.put_env(:nano, :openrouter_backoff_ms, saved) end)
    :ok
  end

  defp start_agent do
    model = FakeOpenRouter.model()
    name = "r#{System.unique_integer([:positive])}"
    FakeOpenRouter.listen(model)
    {:ok, _} = NanoAgent.start([name: name] ++ FakeOpenRouter.opts(model))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    %{name: name, model: model, id: NanoAgent.info(name).id}
  end

  defp eventually(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp entries(id, type), do: for(e <- Nano.Log.read(id), e["type"] == type, do: e)

  defp await(id, type) do
    eventually(fn -> entries(id, type) != [] end)
    hd(entries(id, type))
  end

  defp read(path), do: File.read!(Path.join(RawLog.dir(), path))

  # A recorded file's first line and headers, and its body.
  defp split(path), do: path |> read() |> String.split("\n\n", parts: 2) |> List.to_tuple()

  defp all_recorded do
    for path <- Path.wildcard(Path.join(RawLog.dir(), "**/*")),
        File.regular?(path),
        into: "",
        do: File.read!(path)
  end

  test "off by default: nothing is recorded, and the entries name no file" do
    assert Nano.Settings.get(:raw_model_log) == "off"
    a = start_agent()
    FakeOpenRouter.push(a.model, text: "ok")
    NanoAgent.notify(a.name, :hi)

    assert await(a.id, "model_response")["raw"] == nil
    refute Map.has_key?(await(a.id, "model_request"), "raw")
    refute File.exists?(RawLog.dir())
  end

  test "the setting: off, all, or agent names" do
    for {value, saved} <- [
          {" all ", "all"},
          {"off", "off"},
          {"alice,bob  carol.2", "alice, bob, carol.2"},
          {["alice", "b-1"], "alice, b-1"}
        ] do
      TestSettings.put(:raw_model_log, value)
      assert Nano.Settings.get(:raw_model_log) == saved
    end

    assert RawLog.on?("b-1") and not RawLog.on?("alice2")

    for bad <- ["", "a/b", ["x", 1], 3] do
      assert {:error, "raw_model_log must be off, all, or agent names separated by commas"} =
               Nano.Settings.put(:raw_model_log, bad)
    end

    TestSettings.put(:raw_model_log, "all")
    assert RawLog.on?("anyone")
    assert %{about: about} = Enum.find(Nano.Settings.public(), &(&1.key == :raw_model_log))
    assert about =~ "large" and about =~ "whole conversation"
  end

  test "OpenRouter: the named agents' next requests, as sent and as received, keys redacted" do
    a = start_agent()
    b = start_agent()
    # Applies live, to agents already running.
    TestSettings.put(:raw_model_log, "#{a.name}, someone")

    # Spacing that decoding and encoding again would not keep.
    body =
      ~s({"id": "gen-raw",  "provider":"Fake",\n "choices":[{"index":0,"finish_reason":"stop",) <>
        ~s("message":{"role":"assistant","content":"two  words ","refusal":null}}],) <>
        ~s( "usage":{"prompt_tokens":100,"completion_tokens":10,"cost":0.001}}  \n)

    FakeOpenRouter.push(a.model, status: 200, body: body)
    FakeOpenRouter.push(b.model, text: "ok")
    NanoAgent.notify(a.name, :hi)
    NanoAgent.notify(b.name, :hi)
    model = a.model
    assert_receive {:openrouter_request, ^model, sent}, 2_000
    assert await(a.id, "model_response")["text"] == "two  words "
    await(b.id, "model_response")

    files = ["#{a.id}/1-1.request.txt", "#{a.id}/1-1.response.txt"]
    assert await(a.id, "model_request")["raw"] == ["#{a.id}/1-1.request.txt"]
    assert await(a.id, "model_response")["raw"] == files

    {head, received} = split("#{a.id}/1-1.response.txt")
    assert received == body
    assert head =~ ~r/\AHTTP 200\n/
    assert head =~ "content-type: application/json"

    {head, json} = split("#{a.id}/1-1.request.txt")
    assert head =~ ~r"\APOST http://127.0.0.1:\d+/api/v1/chat/completions\n"
    assert head =~ "\nauthorization: [redacted]\n"
    assert Jason.decode!(json) == sent
    refute all_recorded() =~ "test-key"

    refute File.exists?(Path.join(RawLog.dir(), b.id))
    refute Map.has_key?(await(b.id, "model_request"), "raw")
  end

  test "every attempt is recorded, and each entry names its own" do
    TestSettings.put(:raw_model_log, "all")
    a = start_agent()
    FakeOpenRouter.push(a.model, status: 500)
    FakeOpenRouter.push(a.model, text: "ok")
    NanoAgent.notify(a.name, :hi)

    assert await(a.id, "model_response")["raw"] ==
             ["#{a.id}/1-2.request.txt", "#{a.id}/1-2.response.txt"]

    assert await(a.id, "model_error")["raw"] ==
             ["#{a.id}/1-1.request.txt", "#{a.id}/1-1.response.txt"]

    assert {"HTTP 500" <> _, ~s({"error":) <> _} = split("#{a.id}/1-1.response.txt")
    assert {"HTTP 200" <> _, _} = split("#{a.id}/1-2.response.txt")
    assert elem(split("#{a.id}/1-1.request.txt"), 1) == elem(split("#{a.id}/1-2.request.txt"), 1)
  end

  test "no response at all is recorded as such" do
    TestSettings.put(:raw_model_log, "all")
    a = start_agent()
    # A port that refuses connections.
    TestSettings.put(:openrouter_base_url, "http://127.0.0.1:1/api/v1")
    NanoAgent.notify(a.name, :hi)

    assert %{"status" => nil, "raw" => [request, response]} = await(a.id, "model_error")
    assert {"POST http://127.0.0.1:1/api/v1/chat/completions\n" <> _, _} = split(request)
    assert read(response) =~ ~r/\Ano response: .+\n\z/
  end

  test "the ChatGPT event stream as received, not trimmed; no token or account id" do
    FakeChatGPT.start()
    FakeChatGPT.listen()
    on_exit(fn -> Nano.ChatGPT.Auth.logout() end)
    tokens = FakeChatGPT.tokens()
    FakeChatGPT.auth(:poll, [{200, :approved}])
    FakeChatGPT.auth(:token, [{200, tokens}])
    assert %{status: :pending} = Nano.ChatGPT.Auth.login()
    eventually(fn -> Nano.ChatGPT.Auth.status().status == :connected end)

    model = FakeChatGPT.model()
    name = "c#{System.unique_integer([:positive])}"
    opts = FakeOpenRouter.opts("openai-codex/" <> model, max_context: 272_000)
    {:ok, _} = NanoAgent.start([name: name] ++ opts)
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    id = NanoAgent.info(name).id
    TestSettings.put(:raw_model_log, name)

    # Spaces on both sides of the chunk boundaries, and around the events.
    chunks = [
      ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"r1"}}\n\n) <>
        ~s(event: response.output_item.done\ndata: {"type":"response.output_item.done",) <>
        ~s("item":{"type":"message","role":"assistant","content":[{"type":"output_text",) <>
        ~s("text":"two ),
      ~s( words "}]}}\n\n),
      ~s(event: response.completed\ndata:  {"type":"response.completed","response":) <>
        ~s({"id":"r1","status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}  \n\n \n)
    ]

    # The token is refused once, refreshed, and the request sent again in the same attempt.
    FakeChatGPT.push(model, status: 401)
    FakeChatGPT.push(model, chunks: chunks)
    NanoAgent.notify(name, :hi)

    assert %{"text" => "two  words ", "raw" => raw} = await(id, "model_response")

    assert raw ==
             for(
               n <- ["1-1", "1-1.2"],
               kind <- ["request", "response"],
               do: "#{id}/#{n}.#{kind}.txt"
             )

    {head, stream} = split("#{id}/1-1.2.response.txt")
    assert stream == Enum.join(chunks)
    assert head =~ ~r/\AHTTP 200\n/
    assert head =~ "content-type: text/event-stream"
    assert {"HTTP 401" <> _, _} = split("#{id}/1-1.response.txt")

    for n <- ["1-1", "1-1.2"] do
      {head, _} = split("#{id}/#{n}.request.txt")
      assert head =~ "\nauthorization: [redacted]\n"
      assert head =~ "\nchatgpt-account-id: [redacted]\n"
    end

    recorded = all_recorded()
    refute recorded =~ "Bearer"
    refute recorded =~ tokens["access_token"]
    refute recorded =~ tokens["refresh_token"]
    refute recorded =~ "acct-fake"
  end

  test "a file that cannot be written leaves the call alone, with one warning" do
    TestSettings.put(:raw_model_log, "all")
    a = start_agent()
    # A file where the agent's directory would go.
    File.mkdir_p!(RawLog.dir())
    File.write!(Path.join(RawLog.dir(), a.id), "")
    :persistent_term.erase({RawLog, :warned})
    on_exit(fn -> :persistent_term.erase({RawLog, :warned}) end)

    log =
      capture_log(fn ->
        FakeOpenRouter.push(a.model, text: "fine")
        NanoAgent.notify(a.name, :hi)
        assert %{"text" => "fine", "raw" => nil} = await(a.id, "model_response")
      end)

    assert length(String.split(log, "raw_model_log: could not write")) == 2
    refute NanoAgent.info(a.name).halted
  end

  test "retention: the oldest files go first, past raw_model_log_max_bytes" do
    old = Path.join(RawLog.dir(), "old-agent")
    File.mkdir_p!(old)
    now = System.os_time(:second)

    for {name, age} <- [
          {"1-1.request.txt", 300},
          {"2-1.request.txt", 200},
          {"3-1.request.txt", 100}
        ] do
      path = Path.join(old, name)
      File.write!(path, String.duplicate("x", 1000))
      File.touch!(path, now - age)
    end

    TestSettings.put(:raw_model_log_max_bytes, 2_500)
    RawLog.prune()
    assert File.ls!(old) |> Enum.sort() == ["2-1.request.txt", "3-1.request.txt"]

    # A recorded call keeps its own files, however small the cap.
    TestSettings.put(:raw_model_log_max_bytes, 1)
    TestSettings.put(:raw_model_log, "all")
    a = start_agent()
    FakeOpenRouter.push(a.model, text: "ok")
    NanoAgent.notify(a.name, :hi)
    await(a.id, "model_response")

    assert File.ls!(old) == []

    assert File.ls!(Path.join(RawLog.dir(), a.id)) |> Enum.sort() == [
             "1-1.request.txt",
             "1-1.response.txt"
           ]
  end

  test "the files are served as text from /api/raw, linked from the debug view" do
    TestSettings.put(:raw_model_log, "all")
    a = start_agent()

    FakeOpenRouter.push(a.model,
      status: 200,
      body: ~s({"choices": [{"message": {"content": "<b>hi</b>"}}]})
    )

    NanoAgent.notify(a.name, :hi)
    await(a.id, "model_response")
    path = "#{a.id}/1-1.response.txt"

    conn = get(build_conn(), "/api/raw/" <> path)
    assert response(conn, 200) == read(path)
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    for bad <- [
          "#{a.id}/nope.txt",
          "#{a.id}/..%2F..%2Fstate",
          "..%2F#{a.id}.jsonl",
          a.id,
          "x/y/z"
        ] do
      assert %{"error" => "no such raw_model_log file" <> _} =
               build_conn() |> get("/api/raw/" <> bad) |> json_response(404)
    end

    {:ok, view, _} = live(build_conn(), "/agents/#{a.name}?view=debug")
    assert has_element?(view, ~s(#timeline li.response a[href="/api/raw/#{path}"]))
    assert has_element?(view, ~s(#timeline li.request a[href="/api/raw/#{a.id}/1-1.request.txt"]))
  end
end
