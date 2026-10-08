defmodule Seedling.WebTest do
  use ExUnit.Case, async: true
  alias Seedling.Web
  alias Seedling.Web.{Store, Transport}
  alias Seedling.WebFixture, as: Fixture

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "orion-web-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{opts: [cache_dir: dir], dir: dir}
  end

  test "extracts main content, headings, entities, links, removes executable clutter" do
    html =
      "<title>A &amp; B</title><nav>ignore</nav><main><article><h1>Hello</h1><p>First &lt; second &#x1F600;</p></article><article><p>Last <a href='/docs'>docs</a></p></article><script>ignore()</script></main><footer>ignore</footer>"

    {title, text} = Web.extract(html, "https://site.test/start")
    assert title == "A & B"
    assert text =~ "# Hello"
    assert text =~ "First < second 😀"
    assert text =~ "Last [docs](https://site.test/docs)"
    refute text =~ "ignore"
  end

  test "HTTP fetch pages, caches for a free second look, and cites exact passages", %{opts: opts} do
    owner = self()

    {server, url} =
      Fixture.start(fn conn ->
        send(owner, :request)

        Fixture.text(
          conn,
          "<title>Test</title><main><p>" <> String.duplicate("words ", 3000) <> "</p></main>"
        )
      end)

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert {:ok, page} = Web.fetch(url, opts ++ [limit: 100])
    assert page.source == "http" and not page.cached and page.truncated
    assert page.next_offset == 100
    assert_receive :request
    assert {:ok, next} = Web.read(page.id, opts ++ [offset: page.next_offset, limit: 200])
    assert next.offset == 100 and byte_size(next.text) == 200
    assert {:ok, cached} = Web.fetch(url, opts)
    assert cached.cached
    refute_receive :request, 30
    assert {:ok, cite} = Web.cite(page.id, opts ++ [offset: 100, limit: 200])
    assert cite.quote == next.text and cite.url == url and cite.end_offset == 300
    assert {:ok, refreshed} = Web.fetch(url, opts ++ [refresh: true])
    refute refreshed.cached
    assert_receive :request
  end

  test "Unicode grapheme paging never loses bytes or combines partial characters", %{opts: opts} do
    text = String.duplicate("é😀漢\n", 80)
    {:ok, record} = Store.put("unicode", text, %{}, opts)

    pages =
      Stream.unfold(0, fn
        nil ->
          nil

        offset ->
          {:ok, page} = Store.page(record, offset: offset, limit: 13, max_bytes: 17)
          {page, page.next_offset}
      end)
      |> Enum.to_list()

    assert Enum.map_join(pages, & &1.text) == text
    assert Enum.all?(pages, &(String.valid?(&1.text) and &1.returned_bytes <= 17))
  end

  test "oversized graphemes return actionable errors, offsets checked", %{opts: opts} do
    {:ok, record} = Store.put("huge", "e" <> String.duplicate("́", 100), %{}, opts)
    assert {:error, %{kind: :oversized_grapheme}} = Store.page(record, max_bytes: 4)
    assert {:error, %{kind: :invalid_page}} = Store.page(record, offset: 2)
    assert {:ok, %{text: "", next_offset: nil}} = Store.page(record, offset: 1)
    assert {:error, %{kind: :cache_miss}} = Web.read("../secret", opts)
  end

  test "TTL and bounded cache eviction", %{opts: opts, dir: dir} do
    {:ok, one} = Store.put("one", "one", %{}, opts ++ [cache_entries: 1])
    assert {:error, %{kind: :cache_expired}} = Store.get(one["id"], opts ++ [ttl: -1])
    {:ok, two} = Store.put("two", "two", %{}, opts ++ [cache_entries: 1])
    assert {:ok, _} = Store.get(two["id"], opts)
    assert length(Path.wildcard(Path.join(dir, "*.json"))) == 1
  end

  test "errors are values: status, nontext, unsupported URL, large body, hard deadline", %{
    opts: opts
  } do
    {server, base} =
      Fixture.start(fn conn ->
        case conn.request_path do
          "/missing" ->
            Plug.Conn.send_resp(conn, 404, "no")

          "/pdf" ->
            Fixture.text(conn, "%PDF-1.0", "application/pdf")

          "/big" ->
            Fixture.text(conn, String.duplicate("x", 10000), "text/plain")

          "/slow" ->
            Process.sleep(200)
            Fixture.text(conn, "late")
        end
      end)

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert {:error, %{kind: :http, status: 404}} = Web.fetch(base <> "/missing", opts)
    assert {:error, %{kind: :unsupported_content}} = Web.fetch(base <> "/pdf", opts)
    assert {:error, %{kind: :invalid_url}} = Web.fetch("file:///etc/passwd", opts)
    assert {:error, %{kind: :invalid_url}} = Web.fetch("https://name:password@host.test", opts)

    assert {:error, %{kind: :response_too_large}} =
             Web.fetch(base <> "/big", opts ++ [max_download_bytes: 100])

    assert {:error, %{kind: :timeout}} = Web.fetch(base <> "/slow", opts ++ [timeout: 40])

    assert {:error, %{kind: :network}} =
             Transport.request(:get, "http://127.0.0.1:1", nil, timeout: 100)
  end

  test "probable JavaScript shell is not reported as successful HTTP text", %{opts: opts} do
    {server, url} =
      Fixture.start(fn conn ->
        Fixture.text(
          conn,
          "<div id='root'></div><script>document.querySelector('#root').innerText='rendered'</script>"
        )
      end)

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert {:error, %{kind: :javascript_required}} = Web.fetch(url, opts ++ [mode: :http])
  end

  test "evidence quotes supplied URLs without pretending to prove a claim", %{opts: opts} do
    {server, url} = Fixture.start(fn conn -> Fixture.text(conn, "Evidence.", "text/plain") end)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert {:ok, %{passages: [{:ok, %{quote: "Evidence."}}], note: note}} =
             Web.evidence("A claim", [url], opts)

    assert note =~ "not a verdict"

    assert {:error, %{kind: :too_many_urls}} =
             Web.evidence("claim", List.duplicate(url, 11), opts)
  end
end
