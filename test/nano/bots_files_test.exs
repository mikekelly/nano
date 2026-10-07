defmodule Nano.BotsFilesTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint NanoWeb.Endpoint
  setup do
    root = Path.join(System.tmp_dir!(), "nova-bots-files-#{System.unique_integer([:positive])}")

    {:ok, s} =
      Nano.Bots.start_link(name: {:global, make_ref()}, path: Path.join(root, "state.term"))

    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    File.mkdir_p!(root)
    source = Path.join(root, "source.txt")
    File.write!(source, "<script>not executable</script>")
    on_exit(fn -> File.rm_rf(root) end)
    %{s: s, a: a, chat: chat, root: root, source: source}
  end

  test "produced file is privately copied and forced safe download", c do
    {:ok, file} =
      Nano.Bots.attach(c.chat.id, c.a.id, c.source,
        server: c.s,
        filename: "../<script>bad</script>.html\r\n"
      )

    File.rm!(c.source)
    {:ok, stored} = Nano.Bots.file(file.id, c.s)
    assert File.read!(stored.path) == "<script>not executable</script>"
    refute String.contains?(file.filename, ["/", "\r", "\n"])
    conn = get(build_conn(), "/bots/files/#{file.service}/#{file.id}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert hd(get_resp_header(conn, "content-disposition")) =~ "attachment;"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert hd(get_resp_header(conn, "content-security-policy")) =~ "sandbox"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "unknown IDs/traversal cannot address arbitrary disk files", c do
    service = Nano.Bots.snapshot(c.s).service_id
    assert get(build_conn(), "/bots/files/#{service}/../../etc/passwd").status == 404
    assert get(build_conn(), "/bots/files/#{service}/0000000000000000").status == 404
    assert {:error, :not_found} = Nano.Bots.file("../../etc/passwd", c.s)
  end

  test "symlinks, oversized files and foreign participants are rejected", c do
    link = Path.join(c.root, "link")
    File.ln_s!(c.source, link)
    assert {:error, :not_a_regular_file} = Nano.Bots.attach(c.chat.id, c.a.id, link, server: c.s)
    big = Path.join(c.root, "big")
    File.write!(big, :binary.copy(<<0>>, 5_000_001))
    assert {:error, :file_too_large} = Nano.Bots.attach(c.chat.id, c.a.id, big, server: c.s)

    assert {:error, :invalid_file_or_participant} =
             Nano.Bots.attach(c.chat.id, "foreign", c.source, server: c.s)

    assert Nano.Bots.snapshot(c.s).artifacts == %{}
  end
end
