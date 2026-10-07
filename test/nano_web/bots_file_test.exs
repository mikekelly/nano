defmodule NanoWeb.BotsFileTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  @endpoint NanoWeb.Endpoint

  test "produced HTML downloads as a sandboxed attachment, and traversal ids fail" do
    root = Path.join(System.tmp_dir!(), "bots-download-" <> Vega.Store.id())
    File.mkdir_p!(root)
    path = Path.join(root, "report.html")
    File.write!(path, "<script>alert(1)</script>")

    {:ok, service} =
      start_supervised(
        {Vega.Bots.Server, name: :bots_download_test, root: root, runtime: Vega.BotsTest.Runtime}
      )

    saved = Application.get_env(:nano, :bots_server)
    Application.put_env(:nano, :bots_server, service)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:nano, :bots_server, saved),
        else: Application.delete_env(:nano, :bots_server)

      File.rm_rf(root)
    end)

    {:ok, ref} = Vega.Bots.attach_file(path, server: service)
    c = build_conn() |> get("/bots/files/" <> ref["id"])
    assert c.status == 200
    assert c.resp_body == "<script>alert(1)</script>"
    assert Plug.Conn.get_resp_header(c, "content-type") == ["application/octet-stream"]
    assert hd(Plug.Conn.get_resp_header(c, "content-disposition")) =~ "attachment;"
    assert Plug.Conn.get_resp_header(c, "x-content-type-options") == ["nosniff"]
    assert hd(Plug.Conn.get_resp_header(c, "content-security-policy")) =~ "sandbox"
    c = build_conn() |> get("/bots/files/not-a-hash")
    assert c.status == 404
  end
end
