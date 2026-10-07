defmodule Vega.MCPReferenceTest do
  use ExUnit.Case, async: false
  alias Vega.MCP
  @node System.get_env("VEGA_MCP_REFERENCE_NODE")
  @server System.get_env("VEGA_MCP_REFERENCE_FILESYSTEM")
  @tag skip:
         if(@node && @server,
           do: false,
           else:
             "Set VEGA_MCP_REFERENCE_NODE and VEGA_MCP_REFERENCE_FILESYSTEM for the official reference server"
         )
  test "official MCP filesystem server discovers tools and reads/writes permitted files" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vega-mcp-reference-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir_p!(dir)
    previous = Application.get_env(:nano, :vega_mcp_state_dir)
    Application.put_env(:nano, :vega_mcp_state_dir, Path.join(dir, "state"))
    start_supervised!({Vega.MCP.Supervisor, []})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nano, :vega_mcp_state_dir, previous),
        else: Application.delete_env(:nano, :vega_mcp_state_dir)

      File.rm_rf!(dir)
    end)

    server = "reference-#{System.unique_integer([:positive])}"

    assert {:ok, %{"capabilities" => %{"tools" => _}}} =
             MCP.connect(server, %{"command" => @node, "args" => [@server, dir]})

    assert {:ok, %{"tools" => tools}} = MCP.tools(server)
    assert Enum.any?(tools, &(&1["name"] == "write_file"))
    path = Path.join(dir, "hello.txt")

    assert {:ok, result} =
             MCP.call_tool(server, "write_file", %{
               "path" => path,
               "content" => "hello from Vega MCP"
             })

    refute result["isError"]

    read_tool =
      if Enum.any?(tools, &(&1["name"] == "read_text_file")),
        do: "read_text_file",
        else: "read_file"

    assert {:ok, result} = MCP.call_tool(server, read_tool, %{"path" => path})

    assert Enum.any?(
             result["content"],
             &String.contains?(&1["text"] || "", "hello from Vega MCP")
           )

    assert File.read!(path) == "hello from Vega MCP"
    assert {:ok, result} = MCP.call_tool(server, read_tool, %{"path" => "/etc/passwd"})
    assert result["isError"] == true
  end
end
