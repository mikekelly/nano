defmodule Vega.DelegationMCPTest do
  use ExUnit.Case, async: false
  @moduletag skip: not Code.ensure_loaded?(Vega.MCP)
  test "first child turn calls actual connected stdio MCP tool and reports result" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "delegation-real-mcp")
    File.mkdir_p!(root)
    old = Application.get_env(:nano, :vega_mcp_state_dir)
    Application.put_env(:nano, :vega_mcp_state_dir, root)

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :vega_mcp_state_dir, old),
        else: Application.delete_env(:nano, :vega_mcp_state_dir)
    end)

    start_supervised!({Vega.MCP.Supervisor, []})
    fixture = Path.join(root, "server.py")

    File.write!(fixture, """
    import json, sys
    for line in sys.stdin:
      request = json.loads(line)
      if 'id' not in request: continue
      method = request['method']
      if method == 'initialize':
        result = {'protocolVersion': request['params']['protocolVersion'], 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'delegation-fixture', 'version': '1'}}
      elif method == 'tools/call':
        result = {'content': [{'type': 'text', 'text': 'actual stdio tool ready on first turn'}]}
      elif method == 'tools/list':
        result = {'tools': [{'name': 'ready', 'description': 'ready', 'inputSchema': {'type': 'object'}}]}
      else: result = {}
      print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
    """)

    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    child = "delegation-mcp-#{System.unique_integer([:positive])}"
    server = child <> "-server"

    code =
      "{:ok, value} = Vega.MCP.call_tool(#{inspect(server)}, \"ready\"); Vega.Delegation.report(#{inspect(child)}, %{summary: hd(value[\"content\"])[\"text\"]})"

    Nano.FakeOpenRouter.push(model, calls: [eval: code])

    on_exit(fn ->
      if pid = NanoAgent.whereis(child),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(child)
      Vega.Delegation.unwatch(child)
      apply(Vega.MCP, :disconnect, [server])
    end)

    opts =
      Nano.FakeOpenRouter.opts(model, max_turns: 2) ++
        [
          parent: self(),
          mcp_servers: [{server, %{"command" => "python3", "args" => [fixture]}}],
          message: "go"
        ]

    assert {:ok, _} = Vega.Delegation.subagent(child, opts)

    assert_receive %{
                     delegation: :result,
                     result: %{summary: "actual stdio tool ready on first turn"}
                   },
                   3000
  end
end
