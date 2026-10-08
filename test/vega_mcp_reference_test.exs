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
    # Genuine PNG returned by the official read_media_file tool must not place its
    # bare base64 in eval/transcript/spill JSON. Pixel decoding is deferred to intent.
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    png =
      <<137, 80, 78, 71, 13, 10, 26, 10>> <>
        chunk.("IHDR", <<2::32, 2::32, 8, 2, 0, 0, 0>>) <>
        chunk.("IDAT", :zlib.compress(<<0, 255, 0, 0, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0>>)) <>
        chunk.("IEND", "")

    png_path = Path.join(dir, "media.png")
    File.write!(png_path, png)
    assert {:ok, media} = MCP.call_tool(server, "read_media_file", %{"path" => png_path})
    refute media["isError"]
    part = Enum.find(media["content"], &(&1["type"] == "image"))

    assert %{"type" => "mcp_media_ref", "mimeType" => "image/png", "visible" => false} =
             ref = part["media"]

    refute inspect(media, limit: :infinity) =~ Base.encode64(png)
    assert byte_size(Jason.encode!(media)) < 2048
    assert {:ok, ^ref} = MCP.media_info(ref)

    if Code.ensure_loaded?(Vega.Images) do
      assert {:ok, %{"type" => "image_ref"} = canonical} = MCP.view_image(ref)
      assert canonical in apply(Vega.Images, :take_views, [])
    else
      assert {:error, :images_unavailable} = MCP.view_image(ref)
    end
  end
end
