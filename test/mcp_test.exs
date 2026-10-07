defmodule Nano.MCPTest do
  use ExUnit.Case, async: false
  alias Nano.MCP

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nova-mcp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp server(dir) do
    script = Path.join(dir, "server.py")

    File.write!(script, ~S"""
    import sys,json,signal
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    def out(m):
      print(json.dumps(m), flush=True)
    for line in sys.stdin:
      m=json.loads(line); method=m.get('method'); id=m.get('id')
      if id is None: continue
      if method is None:
        if id=='server-ping' and m.get('result')=={}: out({'jsonrpc':'2.0','method':'fixture/ping_ack'})
        continue
      if method=='hang': continue
      if method=='die': sys.exit(9)
      if method=='initialize': result={'protocolVersion':'2025-11-25','capabilities':{'tools':{},'resources':{'subscribe':True}},'serverInfo':{'name':'fixture','version':'1'}}
      elif method=='tools/list': result={'tools':[{'name':'echo','inputSchema':{'type':'object'}}],'nextCursor':'next'}
      elif method=='resources/list': result={'resources':[{'uri':'test://one','name':'one'}]}
      elif method=='resources/read': result={'contents':[{'uri':m['params']['uri'],'text':'hello'}]}
      elif method=='prompts/list': result={'prompts':[{'name':'greeting'}]}
      elif method=='prompts/get': result={'messages':[{'role':'user','content':{'type':'text','text':'hello'}}]}
      elif method=='tools/call': result={'content':[{'type':'text','text':m['params']['arguments'].get('text','echo')}]}
      elif method in ['resources/subscribe','resources/unsubscribe']: result={}
      elif method=='error':
        out({'jsonrpc':'2.0','id':id,'error':{'code':-32602,'message':'bad'}}); continue
      else: result=m.get('params',{})
      out({'jsonrpc':'2.0','id':id,'result':result})
      if method=='resources/subscribe':
        out({'jsonrpc':'2.0','method':'notifications/resources/updated','params':{'uri':m['params']['uri']}})
        out({'jsonrpc':'2.0','id':'server-ping','method':'ping'})
      if method=='tools/call':
        out({'jsonrpc':'2.0','method':'notifications/tools/list_changed'})
        out({'jsonrpc':'2.0','method':'notifications/progress','params':{'progressToken':1,'progress':1}})
    """)

    name = "fixture-" <> Path.basename(dir)

    assert {:ok, pid} =
             MCP.connect(name,
               config: %{"command" => "python3", "args" => [script]},
               state_dir: dir
             )

    on_exit(fn -> MCP.disconnect(pid) end)
    {name, pid}
  end

  test "stdio lifecycle, discovery, tool/resource/prompt access, events, errors and timeouts", %{
    dir: dir
  } do
    {name, pid} = server(dir)
    assert {:ok, %{ready: true, version: "2025-11-25"}} = MCP.status(pid)
    assert {:ok, %{"tools" => [%{"name" => "echo"}], "nextCursor" => "next"}} = MCP.tools(pid)
    assert {:ok, %{"resources" => [_]}} = MCP.resources(pid)
    assert {:ok, %{"prompts" => [_]}} = MCP.prompts(pid)
    assert {:ok, %{"messages" => [_]}} = MCP.get_prompt(pid, "greeting")
    assert {:ok, %{"contents" => [%{"text" => "hello"}]}} = MCP.read_resource(pid, "test://one")

    assert {:ok, %{"content" => [%{"text" => "hi"}]}} =
             MCP.call_tool(pid, "echo", %{"text" => "hi"})

    assert_receive {:mcp, ^name, "notifications/tools/list_changed", %{}}
    assert_receive {:mcp, ^name, "notifications/progress", %{"progress" => 1}}
    assert :ok = MCP.subscribe(pid, "test://one")
    assert_receive {:mcp, ^name, "notifications/resources/updated", %{"uri" => "test://one"}}
    assert_receive {:mcp, ^name, "fixture/ping_ack", %{}}
    assert :ok = MCP.unsubscribe(pid, "test://one")
    assert {:error, {:rpc, %{"code" => -32602}}} = MCP.request(pid, "error")
    assert {:error, :timeout} = MCP.request(pid, "hang", %{}, timeout: 25)
    assert {:error, {:disconnected, _}} = MCP.request(pid, "die")
    assert_receive {:mcp, ^name, "client/disconnected", _}
    Process.sleep(350)
    assert {:ok, ^pid} = MCP.ready(pid)
  end

  test "stable-name subscription persists across worker and recipient restarts", %{dir: dir} do
    {name, pid} = server(dir)
    recipient_name = "recipient-" <> Path.basename(dir)
    parent = self()

    register = fn ->
      spawn(fn ->
        Registry.register(Nano.Registry, {:agent, recipient_name}, nil)
        send(parent, :registered)

        receive do
          message -> send(parent, {:forwarded, message})
        end
      end)
    end

    recipient = register.()
    assert_receive :registered
    assert :ok = MCP.subscribe(pid, "test://one", recipient_name)
    assert_receive {:forwarded, {:mcp, ^name, "notifications/resources/updated", _}}
    ref = Process.monitor(recipient)
    assert_receive {:DOWN, ^ref, _, _, _}
    register.()
    assert_receive :registered
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert_receive {:forwarded, {:mcp, ^name, "notifications/resources/updated", _}}, 3_000
    assert {:ok, new_pid} = MCP.ready(name)
    assert new_pid != pid
    MCP.disconnect(new_pid)
  end

  test "PID subscribers belonging to an agent automatically use durable identity", %{dir: dir} do
    {_name, pid} = server(dir)
    name = "auto-agent-" <> Path.basename(dir)
    Registry.register(Nano.Registry, {:agent, name}, nil)
    assert :ok = Task.async(fn -> MCP.subscribe(pid, "test://one") end) |> Task.await()
    [path] = Path.wildcard(Path.join(dir, "*.json"))
    assert %{"test://one" => [^name]} = path |> File.read!() |> Jason.decode!()
    assert :ok = MCP.unsubscribe(pid, "test://one")
    assert %{} = path |> File.read!() |> Jason.decode!()
  end

  test "large results spill
 and can be paged",
       %{dir: dir} do
    {_name, pid} = server(dir)

    assert {:ok, %{spilled: true, path: path, bytes: bytes}} =
             MCP.call_tool(pid, "echo", %{"text" => String.duplicate("x", 10_000)},
               max_bytes: 100,
               spill_dir: dir
             )

    assert bytes > 10_000
    assert {:ok, %{data: data, next_offset: 100}} = Nano.MCP.Result.page(path, limit: 100)
    assert byte_size(data) == 100
    assert {:ok, %{"content" => [_]}} = File.read!(path) |> Jason.decode()
  end

  test "unsupported initialization revision is rejected visibly and named disconnect works", %{
    dir: dir
  } do
    {_name, pid} = server(dir)
    assert :ok = MCP.disconnect(pid)
    script = Path.join(dir, "server.py")

    File.write!(
      script,
      File.read!(script)
      |> String.replace("'protocolVersion':'2025-11-25'", "'protocolVersion':'2099-01-01'")
    )

    name = "bad-version-" <> Path.basename(dir)

    assert {:error, {:disconnected, {:initialize, _}}} =
             MCP.connect(name,
               config: %{"command" => "python3", "args" => [script]},
               state_dir: dir
             )

    assert_receive {:mcp, ^name, "client/disconnected", _}
    assert :ok = MCP.disconnect(name)
    assert {:error, :not_found} = MCP.disconnect(name)
  end

  test "SSE framing handles chunk boundaries, comments and multiline data" do
    assert {[], rest} = Nano.MCP.Transport.sse(": keepalive\r\ndata: {\"method\":")

    assert {[%{"method" => "notification"}], "tail"} =
             Nano.MCP.Transport.sse(rest <> "\r\ndata: \"notification\"}\r\n\r\ntail")
  end

  test "config is explicit and rejects malformed files", %{dir: dir} do
    path = Path.join(dir, "config.json")
    File.write!(path, ~s({"mcpServers":{"fixture":{"command":"python3"}}}))
    assert {:ok, %{"fixture" => _}} = MCP.load_config(path)
    assert {:error, :unknown_server} = MCP.connect("absent", config_path: path)
    File.write!(path, "[]")
    assert {:error, :invalid_config} = MCP.load_config(path)
  end
end
