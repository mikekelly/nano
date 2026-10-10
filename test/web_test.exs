defmodule Nano.WebTest.Page do
  use Plug.Router
  plug :match
  plug :dispatch

  get "/article" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      "<html><title>Title &amp; More</title><nav>NOISE</nav><main><h1>Evidence</h1><p>#{String.duplicate("Readable é text. ", 100)}</p><a href='/next'>Next</a><script>BAD SCRIPT</script></main></html>"
    )
  end

  get "/shell" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      "<html><body><main id='root'></main><script>document.getElementById('root').innerHTML='<h1>JavaScript proof</h1><p>Rendered by Lightpanda.</p>';</script></body></html>"
    )
  end

  get "/redirect" do
    conn |> put_resp_header("location", "/article") |> send_resp(302, "")
  end

  get "/long" do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, String.duplicate("é🐈", 20000))
  end

  get "/pdf" do
    conn |> put_resp_content_type("application/pdf") |> send_resp(200, "%PDF fake")
  end

  get "/slow" do
    Process.sleep(1000)
    send_resp(conn, 200, "late")
  end

  match _ do
    send_resp(conn, 404, "missing")
  end
end

defmodule Nano.WebTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nano-web-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    {:ok, server} = Bandit.start_link(plug: Nano.WebTest.Page, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> File.rm_rf(dir) end)
    %{opts: [cache_dir: dir], dir: dir, url: "http://127.0.0.1:#{port}"}
  end

  test "article extraction, redirects, cache and exact evidence", c do
    opts = c.opts ++ [js: false]
    assert {:ok, p} = Nano.Web.fetch(c.url <> "/redirect", opts)
    assert p.url == c.url <> "/article"
    assert p.title == "Title & More"
    assert p.method == "http"
    assert p.text =~ "# Evidence"
    assert p.text =~ "[Next](#{c.url}/next)"
    refute p.text =~ "NOISE"
    refute p.text =~ "BAD SCRIPT"
    assert {:ok, hit} = Nano.Web.fetch(c.url <> "/redirect", opts)
    assert hit.cache_hit
    assert hit.id == p.id
    assert {:ok, e} = Nano.Web.evidence(p.id, "Readable é text.", c.opts)
    assert e.occurrences == 100
    assert e.url == p.url
    assert e.citation =~ p.id
    assert {:error, _} = Nano.Web.evidence(p.id, "invented", c.opts)
    assert {:error, _} = Nano.Web.evidence(p.id, "Readable é text.", c.opts ++ [offset: 0])

    assert {:ok, second} =
             Nano.Web.evidence(p.id, "Readable é text.", c.opts ++ [offset: e.offset])

    assert second.quote == e.quote
  end

  test "Unicode byte bounded paging reassembles all content", c do
    assert {:ok, p} = Nano.Web.fetch(c.url <> "/long", c.opts ++ [js: false, max_bytes: 1001])
    assert p.cut
    assert p.bytes <= 1001
    assert String.valid?(p.text)
    assert {:ok, next} = Nano.Web.read(p.id, c.opts ++ [offset: p.next_offset, max_bytes: 1001])
    assert next.offset == p.next_offset
    assert {:error, _} = Nano.Web.read(p.id, c.opts ++ [offset: 1_000_000])
    assert {:error, _} = Nano.Web.read(p.id, c.opts ++ [max_bytes: 1])

    pages =
      Stream.unfold(0, fn
        nil ->
          nil

        offset ->
          {:ok, r} = Nano.Web.read(p.id, c.opts ++ [offset: offset])
          {r.text, r.next_offset}
      end)
      |> Enum.join()

    assert pages == String.duplicate("é🐈", 20000)
    assert {:ok, end_page} = Nano.Web.read(p.id, c.opts ++ [offset: p.total_chars])
    assert end_page.text == ""
  end

  test "TTL and quota eviction preserve bounded cache", c do
    assert {:ok, p} = Nano.Web.fetch(c.url <> "/article", c.opts ++ [js: false])
    Process.sleep(10)
    assert {:error, _} = Nano.Web.read(p.id, c.opts ++ [ttl: 1])
    assert {:ok, old} = Nano.Web.fetch(c.url <> "/article", c.opts ++ [js: false, max_entries: 1])
    assert {:ok, new} = Nano.Web.fetch(c.url <> "/long", c.opts ++ [js: false, max_entries: 1])
    assert {:error, _} = Nano.Web.read(old.id, c.opts ++ [max_entries: 1])
    assert {:ok, _} = Nano.Web.read(new.id, c.opts)
    assert length(Path.wildcard(Path.join(c.dir, "*.json"))) == 1

    assert {:error, _} =
             Nano.Web.fetch(
               c.url <> "/long",
               c.opts ++ [js: false, refresh: true, max_cache_bytes: 100]
             )

    assert File.ls!(c.dir) == []
  end

  test "unsupported types, invalid options, HTTP failures and total timeouts", c do
    for u <- ["file:///etc/passwd", "https://user:pass@example.com", "https://example.com/ x"] do
      assert {:error, _} = Nano.Web.fetch(u, c.opts)
    end

    assert {:error, _} = Nano.Web.fetch(c.url <> "/pdf", c.opts)
    assert {:error, _} = Nano.Web.fetch(c.url <> "/missing", c.opts)
    assert {:error, _} = Nano.Web.fetch(c.url <> "/slow", c.opts ++ [timeout: 50])
    assert {:error, _} = Nano.Web.fetch(c.url <> "/long", c.opts ++ [max_document_bytes: 100])
    assert {:error, _} = Nano.Web.read("../etc/passwd", c.opts)
    assert {:error, _} = Nano.Web.fetch(c.url, c.opts ++ [timeout: 30001])
    refute Enum.any?(File.ls!(c.dir), &String.starts_with?(&1, "work-"))
  end

  test "real Lightpanda executes JavaScript and auto fallback", c do
    assert System.find_executable("lightpanda")
    assert {:ok, plain} = Nano.Web.fetch(c.url <> "/shell", c.opts ++ [js: false])
    refute plain.text =~ "JavaScript proof"
    assert {:ok, rendered} = Nano.Web.fetch(c.url <> "/shell", c.opts)
    assert rendered.method == "lightpanda"
    assert rendered.text =~ "JavaScript proof"
    assert {:ok, evidence} = Nano.Web.evidence(rendered.id, "Rendered by Lightpanda.", c.opts)
    assert evidence.url == c.url <> "/shell"
    assert {:ok, forced} = Nano.Web.fetch(c.url <> "/shell", c.opts ++ [js: true])
    assert forced.text =~ "JavaScript proof"
  end

  test "CDP wrapper launches a real loopback server and stops its group", c do
    owner = "web-browser-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    assert :yes = Nano.Names.register_name({:agent, owner}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, owner}) end)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)

    assert {:ok, browser} =
             Nano.Web.browser_start(owner: owner, port: port, dir: c.dir, timeout: 10000)

    try do
      result =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case Req.get(browser.endpoint <> "/json/version", retry: false, receive_timeout: 100) do
            {:ok, %{status: 200} = response} ->
              {:halt, response}

            _ ->
              Process.sleep(20)
              {:cont, nil}
          end
        end)

      assert result.status == 200
      assert result.body["webSocketDebuggerUrl"]
      assert :ok = Nano.Web.browser_stop(browser)
      assert_receive {:background, _, %{status: :killed}}, 2000
      assert {:ok, %{status: :killed}} = Nano.Background.status(browser)
    after
      if Process.alive?(browser.pid), do: Nano.Web.browser_stop(browser)
    end
  end

  test "concurrent fetches commit complete snapshots within quotas", c do
    results =
      1..6
      |> Task.async_stream(
        fn _ ->
          Nano.Web.fetch(
            c.url <> "/article",
            c.opts ++ [js: false, refresh: true, max_entries: 3]
          )
        end,
        max_concurrency: 6
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    files = Path.wildcard(Path.join(c.dir, "*.json"))
    assert length(files) <= 3

    for file <- files do
      assert {:ok, entry} = file |> File.read!() |> Jason.decode()
      assert entry["text"] =~ "Readable é text."
    end

    refute Enum.any?(File.ls!(c.dir), &String.starts_with?(&1, "work-"))
  end

  test "corrupt snapshots are rejected and stale workspaces reclaimed", c do
    assert {:ok, p} = Nano.Web.fetch(c.url <> "/article", c.opts ++ [js: false])
    file = Path.join(c.dir, p.id <> ".json")
    entry = File.read!(file) |> Jason.decode!() |> Map.put("text", "tampered")
    File.write!(file, Jason.encode!(entry))
    stale = Path.join(c.dir, "work-abandoned")
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "output"), "stale data")
    File.touch!(stale, System.system_time(:second) - 180)
    assert {:error, _} = Nano.Web.read(p.id, c.opts)
    refute File.exists?(stale)
    refute File.exists?(file)
  end

  test "extraction entities and headings" do
    {title, text} =
      Nano.Web.Extract.html(
        "<title>A</title><body><h2>Header</h2><p>&#x1F408; &lt;safe&gt; &amp; &#233;</p></body>",
        "https://example.org"
      )

    assert title == "A"
    assert text =~ "## Header"
    assert text =~ "🐈 <safe> & é"
  end
end
