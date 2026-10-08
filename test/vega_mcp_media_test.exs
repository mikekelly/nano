defmodule Vega.MCPMediaTest do
  use ExUnit.Case, async: false
  alias Vega.MCP
  @native_images Code.ensure_loaded?(Vega.Images)
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vega-mcp-media-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    saved = Application.get_env(:nano, :vega_mcp_state_dir)
    Application.put_env(:nano, :vega_mcp_state_dir, dir)
    start_supervised!({Vega.MCP.Supervisor, []})

    on_exit(fn ->
      if saved,
        do: Application.put_env(:nano, :vega_mcp_state_dir, saved),
        else: Application.delete_env(:nano, :vega_mcp_state_dir)

      File.rm_rf!(dir)
    end)

    %{dir: dir, png: png()}
  end

  defp png do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk.("IHDR", <<2::32, 2::32, 8, 2, 0, 0, 0>>) <>
      chunk.("IDAT", :zlib.compress(<<0, 255, 0, 0, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0>>)) <>
      chunk.("IEND", "")
  end

  defp image(bytes),
    do: %{
      "type" => "image",
      "mimeType" => "image/png",
      "data" => Base.encode64(bytes),
      "annotations" => %{"audience" => ["assistant"]}
    }

  test "typed images and resource blobs become private refs, text/citations unchanged", ctx do
    base64 = Base.encode64(ctx.png)

    original = %{
      "content" => [
        %{"type" => "text", "text" => "caption", "citations" => ["source://a"]},
        image(ctx.png),
        %{
          "type" => "resource",
          "resource" => %{"uri" => "file:///picture", "mimeType" => "image/png", "blob" => base64}
        }
      ]
    }

    result = Vega.MCP.Media.normalize(original)
    ref = get_in(result, ["content", Access.at(1), "media"])

    assert %{
             "type" => "mcp_media_ref",
             "kind" => "image",
             "visible" => false,
             "verification" => "deferred"
           } = ref

    refute inspect(result, limit: :infinity) =~ base64
    assert hd(result["content"]) == hd(original["content"])
    assert get_in(result, ["content", Access.at(2), "resource", "uri"]) == "file:///picture"
    assert get_in(result, ["content", Access.at(2), "resource", "media"]) == ref
    assert {:ok, ^ref} = MCP.media_info(ref)
    assert {:ok, %{refs: [^ref], files: 1, bytes: bytes}} = MCP.media_page()
    assert bytes == byte_size(ctx.png)
    assert {:error, :invalid_media_page} = MCP.media_page(ref)
    assert {:error, :invalid_media_page} = MCP.media_page(limit: "bad")
    path = Path.join([ctx.dir, "media", ref["id"]])
    assert File.read!(path) == ctx.png
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(path <> ".json").mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    refute File.read!(path <> ".json") =~ base64
  end

  test "invalid/oversized base64, part bounds and unsupported binary never pretend visibility" do
    invalid =
      Vega.MCP.Media.normalize(%{
        "type" => "image",
        "mimeType" => "image/png",
        "data" => "not BASE64!"
      })

    assert invalid["media"]["reason"] == "invalid_base64"
    refute Map.has_key?(invalid, "data")

    oversized =
      Vega.MCP.Media.normalize(%{
        "type" => "image",
        "mimeType" => "image/png",
        "data" => String.duplicate("A", 5_000_001)
      })

    assert oversized["media"]["reason"] == "payload_too_large"
    assert byte_size(Jason.encode!(oversized)) < 400
    many = Vega.MCP.Media.normalize(Enum.map(1..21, fn _ -> image(<<1>>) end))
    assert List.last(many)["media"]["reason"] == "too_many_media_parts"

    binary =
      Vega.MCP.Media.normalize(%{
        "uri" => "resource://binary",
        "mimeType" => "application/octet-stream",
        "blob" => Base.encode64(<<0, 1, 2, 3>>)
      })

    assert binary["media"]["kind"] == "binary"
    assert binary["media"]["visible"] == false

    assert {:error, :unknown_or_corrupt_media} =
             MCP.media_info(%{"type" => "mcp_media_ref", "id" => "../../etc/passwd"})
  end

  test "entry quota, metadata pagination, explicit deletion and disk restart", ctx do
    for n <- 1..128 do
      result =
        Vega.MCP.Media.normalize(%{"uri" => "binary://#{n}", "blob" => Base.encode64(<<n::16>>)})

      assert result["media"]["type"] == "mcp_media_ref"
    end

    excess =
      Vega.MCP.Media.normalize(%{
        "uri" => "binary://excess",
        "blob" => Base.encode64(<<999::16>>)
      })

    assert excess["media"]["reason"] == "media_cache_quota"

    assert {:ok, %{refs: [ref], next_offset: 1, files: 128, bytes: 256}} =
             MCP.media_page(limit: 1)

    assert :ok = Vega.MCP.Media.delete(ref)
    assert {:ok, %{files: 127, refs: [tampered]}} = MCP.media_page(limit: 1)
    metadata = Path.join([ctx.dir, "media", tampered["id"] <> ".json"])

    File.write!(
      metadata,
      Jason.encode!(Map.put(tampered, "mimeType", "untrusted-base64-shaped-metadata"))
    )

    pid = Process.whereis(Vega.MCP.Media.Cache)
    Process.exit(pid, :kill)
    Process.sleep(50)
    assert {:ok, %{files: 127, bytes: 254}} = MCP.media_page(limit: 1)
    assert {:error, :unknown_or_corrupt_media} = MCP.media_info(tampered)
    assert length(File.ls!(Path.join(ctx.dir, "media"))) == 254
  end

  test "total private payload bytes are quota bounded" do
    tail = :binary.copy(<<0>>, 3_749_999)

    for n <- 1..17 do
      assert {:ok, _} =
               Vega.MCP.Media.Cache.store(<<n>> <> tail, "application/octet-stream", "binary")
    end

    assert {:error, :media_cache_quota} =
             Vega.MCP.Media.Cache.store(<<99>> <> tail, "application/octet-stream", "binary")

    assert {:ok, %{files: 17, bytes: 63_750_000}} = MCP.media_page(limit: 1)
  end

  test "RPC, events, async completions and spill JSON never retain image base64", ctx do
    name = "media-#{System.unique_integer([:positive])}"
    agent = name <> "-agent"
    :yes = Nano.Names.register_name({:agent, agent}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, agent}) end)

    config = %{
      "command" => "python3",
      "args" => [Path.expand("vega_mcp_fixture.py", __DIR__)],
      "result_limit" => 256
    }

    assert {:ok, _} = MCP.connect(name, config)
    assert :ok = MCP.watch(name, agent)
    base64 = Base.encode64(ctx.png)

    assert {:ok, %{truncated: true, spill: spill} = bounded} =
             MCP.call_tool(name, "media_image", %{"data" => base64})

    refute inspect(bounded, limit: :infinity) =~ base64
    json = File.read!(spill)
    refute json =~ base64
    assert json =~ "mcp_media_ref"
    assert_receive {:"$gen_cast", {:notify, event}}, 2000
    refute inspect(event, limit: :infinity) =~ base64
    assert {:ok, ref} = MCP.call_tool_async(name, "media_image", %{"data" => base64}, agent)

    assert_receive {:"$gen_cast", {:notify, %{method: "request/completed", ref: ^ref} = event}},
                   2000

    refute inspect(event, limit: :infinity) =~ base64
  end

  test "formatted media cache status and descriptor metadata have no raw payload", ctx do
    raw = Base.encode64(ctx.png)
    result = Vega.MCP.Media.normalize(image(ctx.png))

    status =
      Vega.MCP.Media.Cache.format_status(%{
        state: :sys.get_state(Vega.MCP.Media.Cache),
        message: {:store, raw},
        reason: raw,
        log: [raw]
      })

    refute inspect(status, limit: :infinity) =~ raw
    assert status.message == :redacted
    assert {:ok, ref} = MCP.media_info(result["media"])
    refute Map.has_key?(ref, "data")
    unless @native_images, do: assert({:error, :images_unavailable} = MCP.view_image(ref))
  end

  @tag skip:
         if(@native_images,
           do: false,
           else: "Vega.Images optional integration is not present in the standalone MCP worktree"
         )
  test "explicit native view uses strict Images admission; invalid pixels fail closed", ctx do
    result = Vega.MCP.Media.normalize(image(ctx.png))
    assert {:ok, %{"type" => "image_ref"} = canonical} = MCP.view_image(result["media"])
    assert apply(Vega.Images, :take_views, []) == [canonical]
    # Valid base64 and PNG header aren't a claim that pixels are valid.
    damaged = Vega.MCP.Media.normalize(image(binary_part(ctx.png, 0, 33)))
    assert damaged["media"]["visible"] == false
    assert {:error, _} = MCP.view_image(damaged["media"])
    assert apply(Vega.Images, :take_views, []) == []
  end
end
