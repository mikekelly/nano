defmodule Nano.Bots.AttachmentsTest do
  use ExUnit.Case, async: true
  alias Nano.Bots.Attachments, as: A

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "altair-bots-render-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, opts: [store_dir: dir], dir: dir}
  end

  test "immutable durable file import; filenames never paths", %{opts: opts, dir: dir} do
    name = "../../<svg onload=x>\"\r\n.html"

    assert {:ok, meta} =
             A.import_bytes("<script>active</script>", Keyword.put(opts, :filename, name))

    assert meta.kind == :file
    refute meta.filename =~ "/"
    refute meta.filename =~ "\r"
    refute meta.filename =~ "\""
    assert {:ok, meta} == A.metadata(meta.ref, opts)
    assert {:ok, "<script>active</script>", meta} == A.read(meta.ref, opts)

    assert {:ok, ^meta} =
             A.import_bytes("<script>active</script>", Keyword.put(opts, :filename, name))

    assert length(File.ls!(dir)) == 1
    path = Path.join(dir, "input")
    File.write!(path, "file data")
    assert {:ok, imported} = A.import_file(path, opts)
    assert imported.filename == "input"
  end

  test "bounded imports", %{opts: opts, dir: dir} do
    big = :binary.copy("x", A.max_bytes() + 1)
    assert {:error, :attachment_too_large} = A.import_bytes(big, opts)
    path = Path.join(dir, "big")
    File.write!(path, big)
    assert {:error, :attachment_too_large} = A.import_file(path, opts)
  end

  test "malformed refs, symlinks and altered objects rejected", %{opts: opts, dir: dir} do
    for ref <- [
          "/etc/passwd",
          "attachment:../../etc/passwd",
          "attachment:" <> String.duplicate("A", 64),
          "image:../x",
          nil
        ] do
      assert {:error, _} = A.metadata(ref, opts)
    end

    id = String.duplicate("a", 64)
    File.ln_s!("/etc/passwd", Path.join(dir, id))
    assert {:error, :not_regular_file} = A.read("attachment:" <> id, opts)
    {:ok, meta} = A.import_bytes("data", opts)
    "attachment:" <> id = meta.ref
    path = Path.join(dir, id)
    File.chmod!(path, 0o644)
    File.write!(path, "tampered")
    assert {:error, :hash_mismatch} = A.metadata(meta.ref, opts)
  end

  test "active types and polyglots are download only", %{opts: opts} do
    for {name, bytes} <- [
          {"x.svg", "<svg onload='alert(1)'/>"},
          {"x.html", "<script>alert(1)</script>"},
          {"x.png", "GIF89a<script>x</script>"}
        ] do
      {:ok, meta} = A.import_bytes(bytes, Keyword.put(opts, :filename, name))
      "attachment:" <> id = meta.ref

      conn =
        Plug.Test.conn(:get, "/bots/attachments/" <> id)
        |> Plug.Conn.put_private(:bot_attachment_opts, opts)

      conn = NanoWeb.BotAttachmentController.show(conn, %{"id" => id})
      assert conn.status == 200
      assert conn.resp_body == bytes
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert Plug.Conn.get_resp_header(conn, "content-security-policy") == [
               "sandbox; default-src 'none'"
             ]

      assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert String.starts_with?(disposition, "attachment;")
    end

    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_private(:bot_attachment_opts, opts)
    assert NanoWeb.BotAttachmentController.show(conn, %{"id" => "../../etc/passwd"}).status == 404
  end

  test "images reuse validated shared store and reject active images", %{opts: opts, dir: dir} do
    assert {:error, _} = Nano.Images.import_bytes("<svg/>", opts)

    bytes =
      <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, 44, 0::32, 1::little-16, 1::little-16, 0,
        2, 1, 0, 0, 59>>

    {:ok, image} = Nano.Images.import_bytes(bytes, opts)
    assert {:ok, ref} = A.image_ref(image, opts)
    assert {:ok, meta} = A.metadata(ref, opts)
    assert meta.kind == :image
    assert meta.url == "/api/images/" <> image.image_ref
    assert File.ls!(dir) == [image.image_ref]
    assert {:error, _} = A.image_ref(%{image_ref: "../../etc/passwd"}, opts)
  end
end
