defmodule Seedling.MCPModernTest do
  use ExUnit.Case, async: true
  alias Seedling.MCP

  test "2026-07-28 stateless stdio metadata, subscription correlation, reconnect and bounded spills" do
    dir = Path.join(System.tmp_dir!(), "lyra-mcp-modern-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    fixture = Path.join(dir, "modern.py")

    File.write!(fixture, """
    import sys,json,os
    listen=None
    def out(m): print(json.dumps(dict(jsonrpc='2.0',**m)),flush=True)
    for line in sys.stdin:
      m=json.loads(line); method=m['method']; p=m.get('params',{}); i=m.get('id')
      if i is None:
        if method=='notifications/cancelled': listen=None
        continue
      assert p['_meta']['io.modelcontextprotocol/protocolVersion']=='2026-07-28'
      assert p['_meta']['io.modelcontextprotocol/clientCapabilities']=={}
      if method=='server/discover': r={'resultType':'complete','supportedVersions':['2026-07-28'],'capabilities':{'tools':{},'resources':{'subscribe':True}}}
      elif method=='subscriptions/listen':
        listen=i
        out({'method':'notifications/subscriptions/acknowledged','params':{'_meta':{'io.modelcontextprotocol/subscriptionId':i},'notifications':p['notifications']}})
        continue
      elif method=='tools/call':
        if p['name']=='die': os._exit(3)
        if p['name']=='notify':
          out({'method':'notifications/resources/updated','params':{'uri':'test://one','_meta':{'io.modelcontextprotocol/subscriptionId':listen+99}}})
          out({'method':'notifications/resources/updated','params':{'uri':'test://one','_meta':{'io.modelcontextprotocol/subscriptionId':listen}}})
        r={'resultType':'complete','content':[{'type':'text','text':'ok'}]}
      elif method=='resources/read': r={'resultType':'complete','contents':[{'uri':p['uri'],'text':'é'*30000}],'ttlMs':0,'cacheScope':'private'}
      else: r={'resultType':'complete'}
      out({'id':i,'result':r})
    """)

    parent = self()

    {:ok, c} =
      Seedling.MCP.Client.start_link(
        server_name: "modern",
        server: %{"command" => "python3", "args" => [fixture]},
        state_dir: dir,
        resolver: fn _ -> parent end,
        reconnect_ms: 20
      )

    wait(c)
    assert %{era: :modern, version: "2026-07-28"} = MCP.status(c)
    assert :ok = MCP.subscribe(c, "test://one", "agent")
    assert_receive {:mcp, "modern", "subscription_restored", _}
    assert {:ok, _} = MCP.call_tool(c, "notify")
    assert_receive {:mcp, "modern", "notifications/resources/updated", _}
    refute_receive {:mcp, "modern", "notifications/resources/updated", _}, 30
    assert {:ok, %{spilled: true, path: path, bytes: bytes}} = MCP.read_resource(c, "test://one")
    assert bytes > 12000
    assert {:ok, %{text: text, next_offset: next}} = MCP.result_page(path, limit: 101)
    assert String.valid?(text)
    assert {:ok, %{text: text2}} = MCP.result_page(path, offset: next, limit: 101)
    assert String.valid?(text2)
    assert {:error, {:disconnected, _}} = MCP.call_tool(c, "die")
    wait(c)
    assert_receive {:mcp, "modern", "recovered", %{era: "modern"}}
    assert_receive {:mcp, "modern", "subscription_restored", _}
    MCP.call_tool(c, "notify")
    assert_receive {:mcp, "modern", "notifications/resources/updated", _}
    GenServer.stop(c)
  end

  defp wait(c),
    do:
      Enum.reduce_while(1..100, nil, fn _, _ ->
        if MCP.status(c).ready,
          do: {:halt, :ok},
          else:
            (
              Process.sleep(20)
              {:cont, nil}
            )
      end)
end
