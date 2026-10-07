defmodule SeedlingMCPTest do
  use ExUnit.Case, async: false
  alias Seedling.MCP
  alias Seedling.MCP.Connection

  @fake ~S"""
  import json,sys,os
  mode=sys.argv[1]
  subs=[]
  def send(m):
    sys.stdout.write(json.dumps(m)+'\n');sys.stdout.flush()
  def result(i,r): send({'jsonrpc':'2.0','id':i,'result':r})
  for line in sys.stdin:
    m=json.loads(line);method=m.get('method');i=m.get('id');p=m.get('params',{})
    if method=='server/discover':
      if mode=='legacy': send({'jsonrpc':'2.0','id':i,'error':{'code':-32602,'message':'not initialized'}})
      else: result(i,{'supportedVersions':['2026-07-28'],'capabilities':{'tools':{},'resources':{},'prompts':{}}})
    elif method=='initialize': result(i,{'protocolVersion':'2025-11-25','capabilities':{'tools':{},'resources':{'subscribe':True},'prompts':{}},'serverInfo':{'name':'fake','version':'1'}})
    elif method=='tools/list': result(i,{'tools':[{'name':'echo','inputSchema':{'type':'object'}}],'nextCursor':'page2'})
    elif method=='resources/list': result(i,{'resources':[{'uri':'fake://value','name':'Value'}]})
    elif method=='resources/templates/list': result(i,{'resourceTemplates':[]})
    elif method=='prompts/list': result(i,{'prompts':[{'name':'hello'}]})
    elif method=='prompts/get': result(i,{'messages':[{'role':'user','content':{'type':'text','text':'hello'}}]})
    elif method=='resources/read': result(i,{'contents':[{'uri':p['uri'],'text':'value'}]})
    elif method=='resources/subscribe': subs.append(p['uri']);result(i,{})
    elif method=='resources/unsubscribe': subs.remove(p['uri']);result(i,{})
    elif method=='subscriptions/listen':
      subs=p['notifications']['resourceSubscriptions']
      send({'jsonrpc':'2.0','method':'notifications/subscriptions/acknowledged','params':{'_meta':{'io.modelcontextprotocol/subscriptionId':i},'notifications':p['notifications']}})
    elif method=='tools/call':
      name=p['name']
      if name=='crash': os._exit(9)
      elif name=='hang': pass
      elif name=='error': send({'jsonrpc':'2.0','id':i,'error':{'code':-32602,'message':'bad arguments'}})
      elif name=='large': result(i,{'content':[{'type':'text','text':'x'*60000}]})
      elif name=='meta': result(i,{'meta':p.get('_meta',{})})
      elif name=='emit':
        for uri in subs: send({'jsonrpc':'2.0','method':'notifications/resources/updated','params':{'uri':uri}})
        send({'jsonrpc':'2.0','method':'notifications/tools/list_changed','params':{}})
        result(i,{'content':[{'type':'text','text':'emitted'}]})
      else: result(i,{'content':[{'type':'text','text':json.dumps(p.get('arguments',{}))}]})
  """

  setup %{tmp_dir: dir} do
    # The application boot manager is restarted in an isolated state directory.
    Supervisor.terminate_child(Nano.Supervisor, Seedling.MCP)
    if pid = Process.whereis(Seedling.MCP.Manager), do: GenServer.stop(pid)
    path = Path.join(dir, "mcp.json")
    {:ok, manager} = Seedling.MCP.Manager.start_link(path: path)
    Process.unlink(manager)
    script = Path.join(dir, "fake.py")
    File.write!(script, @fake)
    old_results = Application.get_env(:nano, :mcp_result_dir)
    Application.put_env(:nano, :mcp_result_dir, Path.join(dir, "results"))

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
      if pid = Process.whereis(Seedling.MCP.Manager), do: GenServer.stop(pid)

      if old_results,
        do: Application.put_env(:nano, :mcp_result_dir, old_results),
        else: Application.delete_env(:nano, :mcp_result_dir)

      Supervisor.restart_child(Nano.Supervisor, Seedling.MCP)
    end)

    %{script: script, path: path, manager: manager}
  end

  defp config(script, mode \\ "modern"),
    do: %{"command" => "python3", "args" => ["-u", script, mode]}

  defp register(name), do: Registry.register(Nano.Registry, {:agent, name}, nil)
  defp eventually(fun, count \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, count) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, count - 1)
        )
  end

  @tag :tmp_dir
  test "modern discover, metadata, paged inventory and resource/prompt calls", %{script: script} do
    assert {:ok, %{"supportedVersions" => ["2026-07-28"]}} = MCP.connect("fake", config(script))

    assert {:ok, %{"tools" => [%{"name" => "echo"}], "nextCursor" => "page2"}} =
             MCP.tools("fake", cursor: "page1")

    assert {:ok, %{"resources" => [_]}} = MCP.resources("fake")
    assert {:ok, %{"resourceTemplates" => []}} = MCP.resource_templates("fake")
    assert {:ok, %{"prompts" => [_]}} = MCP.prompts("fake")
    assert {:ok, %{"messages" => [_]}} = MCP.get_prompt("fake", "hello")

    assert {:ok, %{"contents" => [%{"text" => "value"}]}} =
             MCP.read_resource("fake", "fake://value")

    assert {:ok, %{"meta" => meta}} = MCP.call_tool("fake", "meta")
    assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    assert meta["io.modelcontextprotocol/clientCapabilities"] == %{}
    assert {:ok, %{"protocolVersion" => "2026-07-28", "status" => "ready"}} = MCP.info("fake")
  end

  @tag :tmp_dir
  test "legacy fallback works on any preinitialize error and handles RPC errors and timeouts", %{
    script: script
  } do
    assert {:ok, %{"protocolVersion" => "2025-11-25"}} =
             MCP.connect("old", config(script, "legacy"))

    assert {:ok, %{"meta" => %{}}} = MCP.call_tool("old", "meta")
    assert {:error, %{"code" => -32602}} = MCP.call_tool("old", "error")
    assert {:error, :timeout} = MCP.call_tool("old", "hang", %{}, timeout: 30)
    assert {:ok, %{"tools" => [_]}} = MCP.tools("old")
  end

  @tag :tmp_dir
  test "durable subscriptions follow replacement named agent and manager restart", %{
    script: script,
    path: path,
    manager: manager
  } do
    name = "mcp-recipient-#{System.unique_integer([:positive])}"
    register(name)
    assert {:ok, _} = MCP.connect("fake", config(script))
    assert :ok = MCP.subscribe("fake", "fake://value", name)
    assert {:ok, _} = MCP.call_tool("fake", "emit")

    assert_receive {:mcp, "fake", "notifications/resources/updated", %{"uri" => "fake://value"}},
                   1000

    # Simulate the agent's name moving to a replacement mailbox.
    Registry.unregister(Nano.Registry, {:agent, name})
    parent = self()

    replacement =
      spawn(fn ->
        register(name)
        send(parent, :replacement_ready)

        receive do
          msg -> send(parent, {:replacement, msg})
        end
      end)

    assert_receive :replacement_ready
    GenServer.stop(manager)
    {:ok, restored} = Seedling.MCP.Manager.start_link(path: path)
    Process.unlink(restored)
    assert {:ok, pid} = Seedling.MCP.Manager.call({:connection, "fake"})
    assert {:ok, _} = Connection.await(pid, 3000)
    # Ensure manager's asynchronous desired-subscription restore was applied.
    eventually(fn -> :sys.get_state(pid).active == ["fake://value"] end)
    assert {:ok, _} = MCP.call_tool("fake", "emit")
    assert_receive {:replacement, {:mcp, "fake", "notifications/resources/updated", _}}, 1000
    refute Process.alive?(replacement)
    assert {:ok, encoded} = File.read(path)
    assert encoded =~ name
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    GenServer.stop(restored)
  end

  @tag :tmp_dir
  test "server death visible, reconnect restores subscriptions without replaying calls", %{
    script: script
  } do
    name = "mcp-crash-#{System.unique_integer([:positive])}"
    register(name)
    assert {:ok, _} = MCP.connect("fake", config(script), notify: name)
    assert :ok = MCP.subscribe("fake", "fake://value", name)
    assert {:error, {:disconnected, _}} = MCP.call_tool("fake", "crash")
    assert_receive {:mcp, "fake", "connection/down", _}, 1000
    assert_receive {:mcp, "fake", "connection/ready", _}, 3000
    assert_receive {:mcp, "fake", "connection/ready", _}, 3000
    eventually(fn -> match?({:ok, %{"status" => "ready"}}, MCP.info("fake")) end)
    assert {:ok, _} = MCP.call_tool("fake", "emit")
    assert_receive {:mcp, "fake", "notifications/resources/updated", _}, 1000
  end

  @tag :tmp_dir
  test "large/binary data spills, default previews small and config validation", %{script: script} do
    assert {:error, :invalid_config} = MCP.connect("bad", %{})
    assert {:error, :unknown_server} = MCP.tools("missing")
    assert {:ok, _} = MCP.connect("fake", config(script))

    assert {:error, :already_connected_with_different_config} =
             MCP.connect("fake", config(script, "legacy"))

    assert {:ok, %{truncated: true, path: path, bytes: bytes, preview: preview}} =
             MCP.call_tool("fake", "large")

    assert bytes > 60000
    assert byte_size(preview) <= 24000
    assert %{"content" => [%{"text" => text}]} = path |> File.read!() |> Jason.decode!()
    assert byte_size(text) == 60000
    assert :ok = MCP.disconnect("fake")
    assert MCP.servers() == []
  end

  @tag :tmp_dir
  test "legacy subscriptions and unsubscribe", %{script: script} do
    name = "mcp-legacy-#{System.unique_integer([:positive])}"
    register(name)
    assert {:ok, _} = MCP.connect("old", config(script, "legacy"))
    assert :ok = MCP.subscribe("old", "fake://value", name)
    assert {:ok, _} = MCP.call_tool("old", "emit")
    assert_receive {:mcp, "old", "notifications/resources/updated", _}, 1000
    assert :ok = MCP.unsubscribe("old", "fake://value", name)
    assert {:ok, _} = MCP.call_tool("old", "emit")
    refute_receive {:mcp, "old", "notifications/resources/updated", _}, 100
  end
end
