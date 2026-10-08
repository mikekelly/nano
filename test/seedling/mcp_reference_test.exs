defmodule Seedling.MCPReferenceTest do
  use ExUnit.Case, async: false
  @moduletag :mcp_reference
  @moduletag skip:
               is_nil(System.get_env("MCP_REFERENCE_NODE")) or
                 is_nil(System.get_env("MCP_REFERENCE_SERVER"))
  test "real official filesystem server discovers and reads/writes a confined directory" do
    dir =
      Path.join(System.tmp_dir!(), "mcp-reference-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "mcp.json")

    config = %{
      "transport" => "stdio",
      "command" => System.fetch_env!("MCP_REFERENCE_NODE"),
      "args" => [System.fetch_env!("MCP_REFERENCE_SERVER"), dir]
    }

    File.write!(path, Jason.encode!(%{"servers" => %{"reference" => config}}))

    assert {:ok, c} =
             Seedling.MCP.connect("reference", config_path: path, state_dir: dir, timeout: 20_000)

    on_exit(fn -> Seedling.MCP.disconnect(c) end)
    assert {:ok, %{status: :ready, version: "2025-11-25"}} = Seedling.MCP.status(c)
    assert {:ok, result} = Seedling.MCP.tools(c, max_bytes: 100_000)
    names = Enum.map(result.data["tools"], & &1["name"])
    assert "write_file" in names and "read_text_file" in names
    test_file = Path.join(dir, "actual.txt")

    assert {:ok, %{data: %{"content" => [_]}}} =
             Seedling.MCP.call_tool(c, "write_file", %{
               "path" => test_file,
               "content" => "reference verified λ\n"
             })

    assert File.read!(test_file) == "reference verified λ\n"

    assert {:ok,
            %{data: %{"content" => [%{"type" => "text", "text" => "reference verified λ\n"}]}}} =
             Seedling.MCP.call_tool(c, "read_text_file", %{"path" => test_file})

    assert {:ok, %{data: %{"isError" => true}}} =
             Seedling.MCP.call_tool(c, "read_text_file", %{"path" => "/etc/passwd"})
  end
end
