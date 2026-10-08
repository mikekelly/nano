defmodule SeedMCPTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "seed-mcp-test-#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(6))}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.join(dir, "fake.py")

    File.write!(script, """
    import sys,json
    for line in sys.stdin:
      m=json.loads(line)
      if 'id' not in m: continue
      method=m['method']; p=m.get('params',{})
      if method=='server/discover': r={'supportedVersions':['2026-07-28'],'capabilities':{}}
      elif method=='subscriptions/listen':
        print(json.dumps({'jsonrpc':'2.0','method':'notifications/subscriptions/acknowledged','params':{'_meta':{'io.modelcontextprotocol/subscriptionId':m['id']},'notifications':p['notifications']}}),flush=True)
        print(json.dumps({'jsonrpc':'2.0','method':'notifications/resources/updated','params':{'_meta':{'io.modelcontextprotocol/subscriptionId':m['id']},'uri':p['notifications']['resourceSubscriptions'][0]}}),flush=True)
        continue
      elif method=='initialize': r={'protocolVersion':'2025-11-25','capabilities':{'resources':{'subscribe':True}},'serverInfo':{'name':'fake','version':'1'}}
      elif method=='tools/list': r={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
      elif method=='resources/read': r={'contents':[{'uri':p['uri'],'text':'x'*20000}]}
      elif method=='prompts/list': r={'prompts':[]}
      elif method=='tools/call' and p['name']=='oversize':
        print('x'*10000,flush=True); continue
      elif method=='tools/call' and p['name']=='hang': continue
      elif method=='tools/call' and p['name']=='die': sys.exit(7)
      elif method=='tools/call' and p['name']=='error':
        print(json.dumps({'jsonrpc':'2.0','id':m['id'],'error':{'code':-1,'message':'bad'}}),flush=True); continue
      else: r={}
      print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)
      if method=='resources/subscribe':
        print(json.dumps({'jsonrpc':'2.0','method':'notifications/resources/updated','params':{'uri':p['uri']}}),flush=True)
    """)

    opts = [
      owner: self(),
      protocol: "2025-11-25",
      server_name: "fake",
      server: %{"command" => System.find_executable("python3"), "args" => [script]},
      state_dir: dir,
      subscription_key: "owner"
    ]

    %{dir: dir, opts: opts}
  end

  defp ready(c, attempts \\ 100)
  defp ready(_, 0), do: flunk("client never became ready")

  defp ready(c, n) do
    if SeedMCP.status(c).phase != :ready do
      Process.sleep(20)
      ready(c, n - 1)
    end
  end

  test "stdio discovery, subscription events, durable restore, bounded resources", %{opts: opts} do
    {:ok, c} = SeedMCP.start_link(opts)
    ready(c)
    assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = SeedMCP.tools(c)
    assert {:ok, %{}} = SeedMCP.subscribe(c, "file:///example")

    assert_receive %{
      mcp: "fake",
      event: :notification,
      method: "notifications/resources/updated",
      params: %{"uri" => "file:///example"}
    }

    assert {:ok, %{truncated: true, path: path, bytes: bytes}} =
             SeedMCP.read_resource(c, "file:///example")

    assert bytes > 20000
    assert {:ok, %{data: data, next_offset: 100}} = SeedMCP.page(path, limit: 100)
    assert byte_size(data) == 100
    SeedMCP.stop(c)
    {:ok, c} = SeedMCP.start_link(opts)
    ready(c)
    assert_receive %{event: :notification, method: "notifications/resources/updated"}, 1000
    assert SeedMCP.status(c).subscriptions == ["file:///example"]
    assert {:ok, %{}} = SeedMCP.unsubscribe(c, "file:///example")
    SeedMCP.stop(c)
  end

  test "timeouts, JSON-RPC errors and visible reconnect", %{opts: opts} do
    {:ok, c} = SeedMCP.start_link(opts)
    ready(c)
    assert {:error, "MCP request timed out"} = SeedMCP.call_tool(c, "hang", %{}, timeout: 30)
    assert {:error, %{"code" => -1}} = SeedMCP.call_tool(c, "error")
    assert {:error, _} = SeedMCP.call_tool(c, "die")
    assert_receive %{event: :disconnected}, 1000
    ready(c)
    assert {:ok, _} = SeedMCP.tools(c)
    SeedMCP.stop(c)
  end

  test "current revision discovery, metadata and acknowledged subscriptions", %{opts: opts} do
    {:ok, c} = SeedMCP.start_link(Keyword.put(opts, :protocol, "2026-07-28"))
    ready(c)
    assert {:ok, %{"tools" => [_]}} = SeedMCP.tools(c)

    assert {:ok, %{"notifications" => %{"resourceSubscriptions" => ["file:///modern"]}}} =
             SeedMCP.subscribe(c, "file:///modern")

    assert_receive %{
      event: :notification,
      method: "notifications/resources/updated",
      params: %{"uri" => "file:///modern"}
    }

    assert_receive %{event: :notification, method: "notifications/subscriptions/acknowledged"},
                   1000

    SeedMCP.stop(c)
    {:ok, c} = SeedMCP.start_link(Keyword.put(opts, :protocol, "2026-07-28"))
    ready(c)

    assert_receive %{event: :notification, method: "notifications/subscriptions/acknowledged"},
                   1000

    assert {:ok, %{}} = SeedMCP.unsubscribe(c, "file:///modern")
    assert SeedMCP.status(c).subscriptions == []
    SeedMCP.stop(c)
  end

  test "oversized frames disconnect visibly and bad calls are values", %{opts: opts} do
    {:ok, c} = SeedMCP.start_link(Keyword.put(opts, :frame_bytes, 1000))
    ready(c)
    assert {:error, _} = SeedMCP.request(c, nil)
    assert {:error, _} = SeedMCP.call_tool(c, "oversize")
    assert_receive %{event: :disconnected, reason: reason}, 1000
    assert reason =~ "frame"
    SeedMCP.stop(c)
  end

  test "delegation startup awaits readiness, stable handles and runtime restoration", %{
    opts: opts,
    dir: dir
  } do
    owner = "mcp-owner-#{System.unique_integer([:positive])}"

    spec =
      opts[:server] |> Map.put("name", "delegated") |> Map.put("protocolVersion", "2025-11-25")

    assert {:ok, %{"delegated" => via}} = SeedMCP.start_for(owner, [spec], state_dir: dir)
    assert SeedMCP.status(via).phase == :ready
    assert SeedMCP.handles(owner) == %{"delegated" => via}
    assert {:ok, pid} = SeedMCP.connect(spec, owner: owner, state_dir: dir)
    assert GenServer.whereis(via) == pid
    assert {:ok, _} = SeedMCP.subscribe(via, "file:///delegated")
    assert :ok = SeedMCP.Runtime.stop_for(owner)
    assert SeedMCP.handles(owner) == %{}
    assert {:ok, %{"delegated" => ^via}} = SeedMCP.restore(owner, state_dir: dir)
    assert SeedMCP.status(via).subscriptions == ["file:///delegated"]
    assert {:ok, _} = SeedMCP.tools(via)
    assert :ok = SeedMCP.stop(via)
    assert SeedMCP.handles(owner) == %{}
  end

  test "bootstrap event recipient gates first child turn without changing persistence", %{
    opts: opts,
    dir: dir
  } do
    parent = self()
    owner = "mcp-gated-#{System.unique_integer([:positive])}"

    child =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:child_received, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    assert :yes = Nano.Names.register_name({:agent, owner}, child)

    on_exit(fn ->
      Process.exit(child, :kill)
      SeedMCP.Runtime.stop_for(owner)
    end)

    spec = opts[:server] |> Map.put("name", "gated") |> Map.put("protocolVersion", "2025-11-25")

    assert {:ok, %{"gated" => via}} =
             SeedMCP.start_for(owner, [spec], state_dir: dir, event_owner: self())

    assert_receive %{mcp: "gated", event: :connected}
    refute_receive {:child_received, _}, 50
    send(child, {:original_task, "do the work"})
    assert :ok = SeedMCP.owner(via, owner)
    assert {:ok, _} = SeedMCP.subscribe(via, "file:///gated")
    assert_receive {:child_received, {:original_task, "do the work"}}
    assert_receive {:child_received, %{mcp: "gated", event: :request}}
    assert SeedMCP.status(via).subscriptions == ["file:///gated"]
    assert :ok = SeedMCP.Runtime.stop_for(owner)

    assert {:ok, %{"gated" => restored}} =
             SeedMCP.restore(owner, state_dir: dir, event_owner: self())

    assert SeedMCP.status(restored).subscriptions == ["file:///gated"]
    assert :ok = SeedMCP.Runtime.stop_for(owner)
  end

  test "failed runtime startup rolls back new clients", %{dir: dir} do
    owner = "mcp-failed-#{System.unique_integer([:positive])}"
    spec = %{"name" => "bad", "command" => "/not/a/real/command"}
    assert {:error, _} = SeedMCP.start_for(owner, [spec], state_dir: dir, timeout: 50)
    assert SeedMCP.handles(owner) == %{}
    assert {:error, _} = SeedMCP.connect(%{"command" => "missing"}, owner: owner)
  end

  test "configuration and paging errors are values", %{dir: dir} do
    file = Path.join(dir, "config.json")
    File.write!(file, ~s({"mcpServers":{}}))
    assert {:error, message} = SeedMCP.connect("absent", config: file)
    assert message =~ "Unknown MCP server"
    assert {:error, :invalid_page} = SeedMCP.page(file, offset: -1)
  end
end

defmodule SeedMCPTest.HTTPFake do
  use Plug.Router
  plug :match
  plug :dispatch

  get "/mcp" do
    send_resp(conn, 405, "")
  end

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    m = Jason.decode!(body)

    cond do
      m["method"] == "prompts/get" ->
        send_resp(
          conn |> put_resp_content_type("application/json"),
          404,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => m["id"],
            "error" => %{"code" => -32601, "message" => "not found"}
          })
        )

      m["method"] == "subscriptions/listen" ->
        version = get_in(m, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"])
        if version != "2026-07-28", do: raise("missing request metadata")

        if Plug.Conn.get_req_header(conn, "mcp-protocol-version") != [version],
          do: raise("wrong version header")

        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        params = %{
          "_meta" => %{"io.modelcontextprotocol/subscriptionId" => m["id"]},
          "notifications" => m["params"]["notifications"]
        }

        {:ok, conn} =
          chunk(
            conn,
            "data: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/subscriptions/acknowledged",
                "params" => params
              }) <> "\n\n"
          )

        {:ok, conn} =
          chunk(
            conn,
            "data: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/resources/updated",
                "params" => Map.put(params, "uri", "file:///modern")
              }) <> "\n\n"
          )

        Process.sleep(1000)
        conn

      m["method"] == "notifications/initialized" ->
        send_resp(conn, 202, "")

      true ->
        result =
          case m["method"] do
            "server/discover" ->
              %{
                "resultType" => "complete",
                "supportedVersions" => ["2026-07-28"],
                "capabilities" => %{}
              }

            "initialize" ->
              %{
                "protocolVersion" => "2025-11-25",
                "capabilities" => %{},
                "serverInfo" => %{"name" => "http", "version" => "1"}
              }

            "resources/read" ->
              %{"contents" => []}

            _ ->
              %{"tools" => []}
          end

        response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => m["id"], "result" => result})
        conn = put_resp_header(conn, "mcp-session-id", "test-session")

        if m["method"] == "tools/list" do
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

          {:ok, conn} =
            chunk(
              conn,
              "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\r\n\r\n"
            )

          {:ok, conn} = chunk(conn, "data: " <> response <> "\n\n")
          conn
        else
          conn |> put_resp_content_type("application/json") |> send_resp(200, response)
        end
    end
  end
end

defmodule SeedMCPHTTPTest do
  use ExUnit.Case, async: true

  test "current HTTP metadata, POST subscription and cancellation" do
    {:ok, server} = Bandit.start_link(plug: SeedMCPTest.HTTPFake, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, c} =
      SeedMCP.start_link(owner: self(), server: %{"url" => "http://127.0.0.1:#{port}/mcp"})

    assert_receive %{event: :connected, protocol: "2026-07-28"}, 3000
    assert {:ok, %{"notifications" => _}} = SeedMCP.subscribe(c, "file:///modern")
    assert_receive %{event: :notification, method: "notifications/resources/updated"}, 1000
    assert {:ok, %{}} = SeedMCP.unsubscribe(c, "file:///modern")
    assert SeedMCP.status(c).subscriptions == []
    assert SeedMCP.status(c).phase == :ready
    assert {:ok, ack} = SeedMCP.listen(c, %{"toolsListChanged" => true})

    assert :ok =
             SeedMCP.cancel_subscription(
               c,
               get_in(ack, ["_meta", "io.modelcontextprotocol/subscriptionId"])
             )

    assert {:error, %{"code" => -32601}} = SeedMCP.get_prompt(c, "missing")
    assert SeedMCP.status(c).phase == :ready
    SeedMCP.stop(c)
    Supervisor.stop(server)
  end

  test "header values are injection safe and sentinel unambiguous" do
    assert SeedMCP.HTTP.encode_header("plain") == "plain"

    for text <- [" padded ", "line1\nline2", "世界", "=?base64?literal?="] do
      assert SeedMCP.HTTP.encode_header(text) == "=?base64?" <> Base.encode64(text) <> "?="
    end
  end

  test "HTTP JSON initialization and SSE response notifications" do
    {:ok, server} = Bandit.start_link(plug: SeedMCPTest.HTTPFake, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, c} =
      SeedMCP.start_link(
        owner: self(),
        protocol: "2025-11-25",
        server: %{"url" => "http://127.0.0.1:#{port}/mcp"}
      )

    assert_receive %{event: :connected}, 3000
    assert {:ok, %{"tools" => []}} = SeedMCP.tools(c)
    assert_receive %{event: :notification, method: "notifications/tools/list_changed"}
    assert {:ok, %{"contents" => []}} = SeedMCP.read_resource(c, "file:///test")
    SeedMCP.stop(c)
    Supervisor.stop(server)
  end
end
