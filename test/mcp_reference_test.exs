defmodule Seedling.MCPReferenceTest do
  use ExUnit.Case
  @moduletag :mcp_reference
  @moduletag skip: is_nil(System.get_env("MCP_FETCH_COMMAND"))
  test "official fetch reference server discovery and real fetch" do
    command = System.get_env("MCP_FETCH_COMMAND")
    assert is_binary(command), "set MCP_FETCH_COMMAND to mcp-server-fetch executable"
    dir = Path.join(System.tmp_dir!(), "lyra-mcp-ref-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, c} =
      Seedling.MCP.Client.start_link(
        server_name: "fetch-reference",
        server: %{"command" => command},
        state_dir: dir
      )

    Enum.reduce_while(1..300, nil, fn _, _ ->
      if Seedling.MCP.status(c).ready,
        do: {:halt, :ok},
        else:
          (
            Process.sleep(50)
            {:cont, nil}
          )
    end)

    assert Seedling.MCP.status(c).ready
    assert {:ok, [%{"tools" => tools}]} = Seedling.MCP.discover(c).tools
    assert Enum.any?(tools, &(&1["name"] == "fetch"))

    assert {:ok, %{"content" => content} = result} =
             Seedling.MCP.call_tool(c, "fetch", %{
               "url" => "https://example.com",
               "max_length" => 1000
             })

    refute result["isError"]
    assert Enum.any?(content, &String.contains?(&1["text"] || "", "Example Domain"))
    GenServer.stop(c)
  end
end
