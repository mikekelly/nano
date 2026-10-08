defmodule WebAccessTest.Server do
  def init(owner), do: owner

  def call(conn, owner) do
    send(owner, {:requested, conn.request_path})

    case conn.request_path do
      "/html" ->
        reply(
          conn,
          "text/html",
          "<html><head><title>A &amp; B</title><style>hidden</style></head><nav>menu</nav><main><h1>Heading</h1><p>Hello &#x1F30D; &lt;friend&gt;.</p><script>secret</script><a href='/next'>Next</a></main><footer>gone</footer></html>"
        )

      "/large" ->
        reply(conn, "text/plain", String.duplicate("abcdef", 400_000))

      "/text" ->
        reply(conn, "text/plain", String.duplicate("🌍 abc\n", 10_000))

      "/slow" ->
        Process.sleep(500)
        reply(conn, "text/plain", "late")

      "/redirect" ->
        conn |> Plug.Conn.put_resp_header("location", "/html") |> Plug.Conn.send_resp(302, "")

      "/pdf" ->
        reply(conn, "application/pdf", "%PDF")

      "/gzip" ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> reply("text/plain", :zlib.gzip("compressed"))

      "/binary" ->
        reply(conn, "text/plain", <<255>>)

      _ ->
        Plug.Conn.send_resp(conn, 429, "do not expose raw provider error")
    end
  end

  defp reply(conn, type, text),
    do: conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.send_resp(200, text)
end

defmodule WebAccessTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "deneb-web-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, server} =
      Bandit.start_link(plug: {WebAccessTest.Server, self()}, port: 0, ip: {127, 0, 0, 1})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{dir: dir, url: "http://127.0.0.1:#{port}", opts: [cache_dir: dir]}
  end

  test "HTTP extraction, metadata, free cache hit, refresh and exact evidence", c do
    url = c.url <> "/html"
    assert {:ok, p} = WebAccess.fetch(url, c.opts)
    assert_receive {:requested, "/html"}
    assert p.title == "A & B"
    assert p.text =~ "# Heading"
    assert p.text =~ "Hello 🌍 <friend>."
    assert p.text =~ "[Next](#{c.url}/next)"
    refute p.text =~ "secret"
    refute p.text =~ "menu"
    refute p.text =~ "gone"
    assert {:ok, %{cached: true, id: id}} = WebAccess.fetch(url, c.opts)
    assert id == p.id
    refute_receive {:requested, _}, 30
    assert {:ok, %{cached: false}} = WebAccess.fetch(url, c.opts ++ [refresh: true])
    assert_receive {:requested, "/html"}
    assert {:ok, quote} = WebAccess.cite(p.id, "Hello 🌍", c.opts)
    assert quote.sha256 == p.sha256
    assert binary_part(p.text, quote.offset, quote.end_offset - quote.offset) == quote.quote
    assert quote.url == url
    assert {:error, :quote_not_found} = WebAccess.cite(p.id, "invented", c.opts)
    assert {:error, _} = WebAccess.cite(p.id, "", c.opts)
  end

  test "UTF8 pages reconstruct text without holes, loops or unannounced truncation", c do
    text = String.duplicate("🌍abc", 100)
    assert {:ok, first} = WebAccess.store(c.url, text, c.opts ++ [bytes: 5])

    pages =
      Stream.unfold(first, fn
        nil ->
          nil

        p ->
          next =
            if p.next_offset do
              {:ok, next} = WebAccess.read(p.id, c.opts ++ [offset: p.next_offset, bytes: 5])
              next
            end

          {p.text, next}
      end)
      |> Enum.to_list()

    assert Enum.join(pages) == text
    assert Enum.all?(pages, &(byte_size(&1) <= 5 and String.valid?(&1)))
    assert {:error, :offset_not_utf8_boundary} = WebAccess.read(first.id, c.opts ++ [offset: 1])
    assert {:error, {:offset_past_end, 700}} = WebAccess.read(first.id, c.opts ++ [offset: 701])

    assert {:ok, %{text: "", next_offset: nil}} =
             WebAccess.read(first.id, c.opts ++ [offset: 700])

    assert {:error, _} = WebAccess.read(first.id, c.opts ++ [bytes: 3])
    assert {:error, _} = WebAccess.read(first.id, c.opts ++ [bytes: 24001])
  end

  test "network errors, response size, total timeout, content types and redirects", c do
    assert {:error, {:http_status, 429}} = WebAccess.fetch(c.url <> "/error", c.opts)
    assert {:error, {:response_too_large, 2_000_000}} = WebAccess.fetch(c.url <> "/large", c.opts)
    assert {:error, :timeout} = WebAccess.fetch(c.url <> "/slow", c.opts ++ [timeout: 40])

    assert {:error, {:unsupported_content_type, "application/pdf"}} =
             WebAccess.fetch(c.url <> "/pdf", c.opts)

    assert {:error, :unexpected_content_encoding} = WebAccess.fetch(c.url <> "/gzip", c.opts)

    assert {:error, :invalid_utf8_response} = WebAccess.fetch(c.url <> "/binary", c.opts)
    assert {:ok, redirected} = WebAccess.fetch(c.url <> "/redirect", c.opts)
    assert redirected.title == "A & B"
    assert redirected.url == c.url <> "/html"
    assert {:ok, %{cached: true}} = WebAccess.fetch(c.url <> "/redirect", c.opts)
    assert {:ok, %{bytes: 11997, next_offset: 11997}} = WebAccess.fetch(c.url <> "/text", c.opts)
  end

  test "invalid URLs and inputs return errors rather than raising", c do
    for url <- [
          "file:///etc/passwd",
          "https://user:password@example.org",
          "https://",
          "https://exa mple.org",
          nil,
          123
        ] do
      assert {:error, _} = WebAccess.fetch(url, c.opts)
    end

    assert {:error, :invalid_id} = WebAccess.read("../escape", c.opts)
    assert {:error, :invalid_utf8_text} = WebAccess.store(c.url, <<255>>, c.opts)
    assert {:error, _} = WebAccess.fetch(c.url, c.opts ++ [timeout: 26000])
  end

  test "disk expiration, bounded entries, corruption and source truncation", c do
    assert {:ok, p} = WebAccess.store(c.url, String.duplicate("🌍", 300_000), c.opts)
    assert p.total_bytes == 1_000_000
    assert p.source_truncated
    assert p.bytes == 12000
    path = Path.join(c.dir, p.id <> ".json")
    old = Jason.decode!(File.read!(path)) |> Map.put("fetched_at", 0)
    File.write!(path, Jason.encode!(old))
    assert {:error, :cache_miss_or_expired} = WebAccess.read(p.id, c.opts)
    for i <- 1..35, do: assert({:ok, _} = WebAccess.store(c.url <> "/#{i}", "entry #{i}", c.opts))
    assert length(Path.wildcard(c.dir <> "/*.json")) == 32
    refute File.exists?(path)
    [file | _] = Path.wildcard(c.dir <> "/*.json")
    File.write!(file, "broken")
    assert {:error, :cache_miss_or_expired} = WebAccess.read(Path.basename(file, ".json"), c.opts)
  end

  test "refresh replaces URL lookup while unrelated pages stay readable", c do
    assert {:ok, p} = WebAccess.store(c.url, "old", c.opts ++ [mode: "http"])
    assert {:ok, q} = WebAccess.store(c.url, "new", c.opts ++ [mode: "http"])
    assert p.id != q.id
    assert {:ok, %{text: "new", cached: true}} = WebAccess.fetch(c.url, c.opts)
  end

  test "browser integration caches full rendering while public browser output stays small", c do
    executable = Path.join(c.dir, "fake-browser")
    File.write!(executable, "#!/bin/sh\nprintf '%s' '" <> String.duplicate("x", 60_000) <> "'\n")
    File.chmod!(executable, 0o755)

    assert {:ok, page} =
             WebAccess.fetch(c.url, c.opts ++ [browser: true, executable: executable, bytes: 500])

    assert page.mode == "browser"
    assert page.bytes == 500
    assert page.total_bytes == 60_000
    assert page.next_offset == 500
    assert {:ok, next} = WebAccess.read(page.id, c.opts ++ [offset: 500, bytes: 500])
    assert next.offset == 500
    assert next.bytes == 500
    assert {:ok, direct} = WebAccess.Browser.fetch(c.url, executable: executable)
    assert byte_size(direct.text) <= 12_000
    assert direct.truncated
  end

  test "HTML entities, excluded markup, unsafe links, plain fallbacks" do
    p =
      WebAccess.HTML.extract(
        "<title>Test</title><article><p>A &amp; B &#65; &#xD800;.</p><a href='javascript:alert(1)'>bad</a><a href='/ok'>ok</a></article>",
        "https://example.org/base"
      )

    assert p.text =~ "A & B A &#xD800;."
    refute p.text =~ "javascript"
    assert p.text =~ "[ok](https://example.org/ok)"
  end
end
