defmodule Nano.MCPTest do
  @moduledoc """
  MCP against a fake stdio server (a real subprocess, real JSON-RPC) and against the pure framing
  functions. The reference-server check is described in `/app/README.seedling.md`: it needs `npx`
  and the network, so it is a scripted check, not a unit test.
  """
  use ExUnit.Case, async: false

  alias Nano.MCP.JSONRPC, as: P

  test "take_message pulls one newline-delimited message out of a buffer" do
    assert {:ok, %{"id" => 1}, "rest"} = P.take_message(~s({"id":1}\nrest))
    assert :more = P.take_message(~s({"id":1}))
    assert {:invalid, _reason, "ok"} = P.take_message("not json\nok")
  end

  test "decode_sse reads data: events, including multi-line ones" do
    body = "event: message\ndata: {\"id\":1}\n\ndata: {\"id\":2}\n"
    assert [%{"id" => 1}, %{"id" => 2}] = P.decode_sse(body)
  end

  test "normalize_result keeps text, references binary and caps long text" do
    result = %{"content" => [%{"type" => "text", "text" => "hello"},
                             %{"type" => "image", "data" => String.duplicate("A", 40), "mimeType" => "image/png"}]}
    out = P.normalize_result(result)
    assert out["text"] == "hello"
    [text, image] = out["content"]
    assert text["text"] == "hello"
    assert image["data"] =~ "<image:"
    assert image["bytes"] == 40
  end

  test "normalize_result caps long text" do
    long = String.duplicate("x", 20_000)
    out = P.normalize_result(%{"content" => [%{"type" => "text", "text" => long}]})
    assert String.length(out["text"]) < 20_000
    assert out["content"] |> hd() |> Map.has_key?("text")
  end

  @tag :fake
  test "connect to a fake stdio server: era probe falls back to initialize, tools list, tool call, notification" do
    script = Path.join(System.tmp_dir!(), "fake_mcp_test.py")
    File.write!(script, fake_server())
    self_pid = self()

    {:ok, info} = Nano.MCP.connect("fake-test-#{System.unique_integer([:positive])}", ["python3", script], await: 10_000)
    assert info.era == :legacy
    assert info.protocolVersion == "2025-06-18"
    assert info.serverInfo["name"] == "fake"

    id = info.id
    assert [%{"name" => "echo"}] = Nano.MCP.tools(id)
    assert {:ok, %{"text" => text}} = Nano.MCP.call(id, "echo", %{})

    # A notification arrives as a message to the subscriber (this test process, via `pid:`).
    Nano.MCP.subscribe(id, agent: self_pid, uri: "mem://x")
    assert_receive {:mcp, %{server: ^id, method: "notifications/resources/updated"}}, 5_000
    assert text =~ "echo"
  end

  defp fake_server do
    """
    import sys, json, threading, time
    def send(m): sys.stdout.write(json.dumps(m)+"\\n"); sys.stdout.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        m = json.loads(line)
        meth = m.get("method")
        if meth == "server/discover":
            send({"jsonrpc":"2.0","id":m["id"],"error":{"code":-32601,"message":"Method not found"}})
        elif meth == "initialize":
            send({"jsonrpc":"2.0","id":m["id"],"result":{"protocolVersion":"2025-06-18",
                  "serverInfo":{"name":"fake","version":"0"},"capabilities":{"resources":{"subscribe":True}}}})
        elif meth == "tools/list":
            send({"jsonrpc":"2.0","id":m["id"],"result":{"tools":[{"name":"echo","description":"e","inputSchema":{"type":"object"}}]}})
        elif meth == "tools/call":
            send({"jsonrpc":"2.0","id":m["id"],"result":{"content":[{"type":"text","text":"echo:"+json.dumps(m["params"].get("arguments",{}))}]}})
        elif meth == "resources/subscribe":
            send({"jsonrpc":"2.0","id":m["id"],"result":{}})
            def later():
                time.sleep(0.3)
                send({"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":m["params"]["uri"]}})
            threading.Thread(target=later, daemon=True).start()
        elif meth and m.get("id") is not None:
            send({"jsonrpc":"2.0","id":m["id"],"result":{}})
    """
  end
end
