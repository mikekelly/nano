defmodule Seedling.MCPTest do
  use ExUnit.Case, async: true
  alias Seedling.MCP
  defp ready(c, n \\ 100)
  defp ready(_, 0), do: flunk("not ready")

  defp ready(c, n) do
    if MCP.status(c).ready,
      do: :ok,
      else:
        (
          Process.sleep(20)
          ready(c, n - 1)
        )
  end

  test "real stdio fixture: discovery, errors, timeout, events, agent/client/server restart" do
    dir = Path.join(System.tmp_dir!(), "lyra-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    fixture = Path.join(dir, "server.py")

    File.write!(fixture, """
    import sys,json,os
    def out(m):
      print(json.dumps(dict(jsonrpc='2.0',**m)),flush=True)
    for line in sys.stdin:
      m=json.loads(line); method=m.get('method'); p=m.get('params',{}); i=m.get('id')
      if i is None: continue
      if method=='initialize': r={'protocolVersion':'2025-11-25','capabilities':{'resources':{'subscribe':True},'tools':{},'prompts':{}},'serverInfo':{'name':'fixture','version':'1'}}
      elif method=='tools/list': r={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
      elif method=='resources/list': r={'resources':[{'uri':'test://one','name':'one'}]}
      elif method=='resources/templates/list': r={'resourceTemplates':[]}
      elif method=='prompts/list': r={'prompts':[]}
      elif method=='resources/read': r={'contents':[{'uri':p['uri'],'text':'hello'}]}
      elif method in ('resources/subscribe','resources/unsubscribe'): r={}
      elif method=='tools/call':
        if p['name']=='die': os._exit(3)
        if p['name']=='hang': continue
        if p['name']=='notify': out({'method':'notifications/resources/updated','params':{'uri':'test://one'}})
        r={'content':[{'type':'text','text':json.dumps(p.get('arguments',{}))}]}
      else:
        out({'id':i,'error':{'code':-32601,'message':'unknown'}}); continue
      out({'id':i,'result':r})
    """)

    table = :ets.new(:routes, [:public])
    :ets.insert(table, {"agent", self()})

    resolver = fn name ->
      case :ets.lookup(table, name) do
        [{_, pid}] -> pid
        _ -> nil
      end
    end

    opts = [
      server: %{"command" => "python3", "args" => [fixture]},
      server_name: "fixture",
      state_dir: dir,
      resolver: resolver,
      reconnect_ms: 20
    ]

    {:ok, c} = Seedling.MCP.Client.start_link(opts)
    ready(c)
    assert {:ok, [%{"tools" => [_]}]} = MCP.discover(c).tools
    assert {:ok, %{"contents" => [_]}} = MCP.read_resource(c, "test://one")
    assert {:error, %{"code" => -32601}} = MCP.request(c, "missing")
    assert {:error, :timeout} = MCP.request(c, "tools/call", %{"name" => "hang"}, 20)
    assert :ok = MCP.subscribe(c, "test://one", "agent")
    MCP.call_tool(c, "notify")
    assert_receive {:mcp, "fixture", "notifications/resources/updated", %{"uri" => "test://one"}}
    # Replace route as NanoAgent.whereis would after an agent restart.
    parent = self()

    replacement =
      spawn(fn ->
        receive do
          msg -> send(parent, {:replacement, msg})
        end
      end)

    :ets.insert(table, {"agent", replacement})
    MCP.call_tool(c, "notify")
    assert_receive {:replacement, {:mcp, "fixture", "notifications/resources/updated", _}}
    :ets.insert(table, {"agent", self()})
    assert {:error, {:disconnected, _}} = MCP.call_tool(c, "die")
    ready(c)
    MCP.call_tool(c, "notify")
    assert_receive {:mcp, "fixture", "notifications/resources/updated", _}
    GenServer.stop(c)
    {:ok, c2} = Seedling.MCP.Client.start_link(opts)
    ready(c2)
    MCP.call_tool(c2, "notify")
    assert_receive {:mcp, "fixture", "notifications/resources/updated", _}
    assert :ok = MCP.unsubscribe(c2, "test://one", "agent")
    GenServer.stop(c2)
    config = Path.join(dir, "config.json")
    File.write!(config, Jason.encode!(%{"mcpServers" => %{"fixture" => opts[:server]}}))

    {:ok, sup} =
      Seedling.MCP.Supervisor.start_link(config: config, state_dir: dir, resolver: resolver)

    assert {:ok, supervised} = MCP.ensure_connection("fixture", supervisor: sup, config: config)
    ready(supervised)
    assert :ok = MCP.watch(supervised, "agent")
    Process.exit(supervised, :kill)
    Process.sleep(30)
    assert {:ok, restarted} = MCP.ensure_connection("fixture", supervisor: sup, config: config)
    refute restarted == supervised
    ready(restarted)
    assert_receive {:mcp, "fixture", "connected", _}

    assert {:error, :unknown_server} =
             MCP.ensure_connection("absent", supervisor: sup, config: config)

    Supervisor.stop(sup)
  end
end
