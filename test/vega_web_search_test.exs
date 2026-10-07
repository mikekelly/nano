defmodule Vega.WebSearchTest.Server do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    send(opts[:owner], {:request, conn.method, conn.request_path, body})

    case conn.request_path do
      "/page" ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(
          200,
          "<html><title>Title</title><nav>NOISE</nav><main><h1>Hello</h1><p>" <>
            String.duplicate("Readable &amp; real. ", 50) <>
            "</p><script>secret</script></main></html>"
        )

      "/js" ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(
          200,
          "<html><body><main id='content'></main><script>document.getElementById('content').textContent='JS-RENDERED-EVIDENCE: ' + 'Readable browser content. '.repeat(12);</script></body></html>"
        )

      "/shell" ->
        conn |> put_resp_content_type("text/html") |> send_resp(200, "<div id='root'></div>")

      "/big" ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, String.duplicate("z", 10000))

      "/slow" ->
        Process.sleep(300)
        send_resp(conn, 200, "slow")

      "/agent/runs/pending" ->
        json(conn, 200, %{id: "pending", status: "running"})

      "/agent/runs/failed" ->
        json(conn, 200, %{id: "failed", status: "failed", error: "should not echo"})

      "/pdf" ->
        conn |> put_resp_content_type("application/pdf") |> send_resp(200, "%PDF")

      "/search" ->
        json(conn, 200, %{
          results: [
            %{
              id: "one",
              url: "https://example.org",
              title: "Result",
              highlights: [String.duplicate("x", 2000)],
              text: "MUST NOT RETURN"
            }
          ]
        })

      "/contents" ->
        json(conn, 200, %{
          results: [
            %{
              id: "https://example.org",
              url: "https://example.org",
              title: "Result",
              text: String.duplicate("contents ", 1000)
            }
          ]
        })

      "/answer" ->
        json(conn, 200, %{
          answer: "Fact [1]",
          citations: [%{id: "one", url: "https://example.org", title: "Evidence"}]
        })

      "/agent/runs" ->
        json(conn, 200, %{id: "test-run", status: "queued"})

      "/agent/runs/test-run" ->
        json(conn, 200, %{
          id: "test-run",
          status: "completed",
          output: %{
            text: "Done",
            structured: %{fact: 42},
            grounding: [%{url: "https://example.org"}]
          }
        })

      "/rate/search" ->
        conn |> put_resp_header("retry-after", "3") |> send_resp(429, "secret echoed")

      _ ->
        send_resp(conn, 404, "missing")
    end
  end

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end

defmodule Vega.WebSearchTest do
  use ExUnit.Case, async: true
  alias Vega.Web.Cache

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vega-web-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)

    {:ok, server} =
      Bandit.start_link(
        plug: {Vega.WebSearchTest.Server, [owner: self()]},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, url: "http://127.0.0.1:#{port}", server: server}
  end

  test "HTTP extraction, cached paging, refresh and provenance", c do
    opts = [cache_dir: c.dir, limit: 50, javascript: false]
    assert {:ok, page} = Vega.Web.fetch(c.url <> "/page", opts)
    assert page.source == c.url <> "/page"
    assert page.title == "Title"

    assert {:ok, %{title: "Title"}} =
             Vega.Web.fetch(c.url <> "/page", cache_dir: c.dir, refresh: true)

    assert_receive {:request, "GET", "/page", _}
    assert page.next == 50
    refute String.contains?(page.text, ["NOISE", "secret"])
    assert_receive {:request, "GET", "/page", _}
    assert {:ok, %{offset: 50, text: more}} = Vega.Web.read(page.id, opts ++ [offset: 50])
    assert String.length(more) == 50
    assert {:ok, %{cached: true}} = Vega.Web.fetch(c.url <> "/page", opts)
    refute_receive {:request, _, _, _}, 50
    assert {:ok, _} = Vega.Web.fetch(c.url <> "/page", opts ++ [refresh: true])
    assert_receive {:request, "GET", "/page", _}
  end

  test "bounded transport, unsupported formats and URL errors", c do
    assert {:error, :response_too_large} =
             Vega.Web.fetch(c.url <> "/big", cache_dir: c.dir, max_bytes: 100)

    assert {:error, {:unsupported_content_type, "application/pdf; charset=utf-8"}} =
             Vega.Web.fetch(c.url <> "/pdf", cache_dir: c.dir)

    assert {:error, {:http_status, 404}} = Vega.Web.fetch(c.url <> "/missing", cache_dir: c.dir)
    assert {:error, :invalid_url} = Vega.Web.fetch("file:///etc/passwd")
    assert {:error, :invalid_url} = Vega.Web.fetch("https://user:pass@example.org")
  end

  test "persistent Unicode paging, TTL, traversal rejection and eviction", c do
    assert {:ok, id} = Cache.put("key", "αβ😀end", %{url: "https://example.org"}, cache_dir: c.dir)
    assert {:ok, %{text: "αβ😀", next: 3}} = Cache.read(id, cache_dir: c.dir, limit: 3)
    assert {:ok, %{text: "end", next: nil}} = Cache.read(id, cache_dir: c.dir, offset: 3)
    assert {:error, {:invalid_page, 6}} = Cache.read(id, cache_dir: c.dir, offset: -1)
    assert {:error, :expired} = Cache.read(id, cache_dir: c.dir, ttl: -1)
    assert {:error, :invalid_id} = Cache.read("../../settings", cache_dir: c.dir)
    for n <- 1..5, do: Cache.put("key#{n}", "value", %{}, cache_dir: c.dir, max_entries: 2)
    assert length(Path.wildcard(c.dir <> "/*.json")) <= 2
    assert {:ok, truncated} = Cache.put("cut", "123456", %{}, cache_dir: c.dir, content_limit: 3)
    assert {:ok, %{text: "123", truncated: true}} = Cache.read(truncated, cache_dir: c.dir)
  end

  test "search is compact, content stored, answer citations preserved", c do
    opts = [api_key: "fake-key", base_url: c.url, cache_dir: c.dir]
    assert {:ok, %{results: [result]}} = Vega.Search.search("query", opts)
    assert String.length(hd(result.highlights)) == 1000
    refute Map.has_key?(result, :text)
    assert_receive {:request, "POST", "/search", raw}
    assert Jason.decode!(raw)["contents"] == %{"highlights" => %{"maxCharacters" => 1000}}

    assert {:ok, %{results: [%{content_id: id}]}} =
             Vega.Search.contents(["https://example.org"], opts)

    assert {:ok, %{text: text}} = Vega.Web.read(id, cache_dir: c.dir)
    assert String.starts_with?(text, "contents ")

    assert {:ok, %{answer: "Fact [1]", citations: [%{url: "https://example.org"}]}} =
             Vega.Search.answer("question", opts)
  end

  test "missing key and rate limits are redacted values", c do
    assert {:error, :missing_exa_api_key} = Vega.Search.search("query", api_key: nil)

    assert {:error, err} =
             Vega.Search.search("query", api_key: "fake-key", base_url: c.url <> "/rate")

    assert err == %{service: :exa, status: 429, retry_after: "3"}
    refute inspect(err) =~ "secret"
  end

  test "wall-clock HTTP deadline returns a value", c do
    assert {:error, :timeout} = Vega.Web.fetch(c.url <> "/slow", cache_dir: c.dir, timeout: 30)
  end

  test "async research event and persisted structured output survive initiating process", c do
    opts = [
      api_key: "fake-key",
      base_url: c.url,
      cache_dir: c.dir,
      notify: self(),
      agent: nil,
      poll_interval: 10
    ]

    parent = self()

    starter =
      spawn(fn -> send(parent, {:started, Vega.Search.research("brief research", opts)}) end)

    ref = Process.monitor(starter)
    assert_receive {:started, {:ok, %{run_id: "test-run"}}}
    assert_receive {:DOWN, ^ref, :process, ^starter, :normal}

    assert_receive {:vega_research, {:ok, %{status: "completed", content_id: id, text: "Done"}}},
                   2000

    assert {:ok, %{text: raw}} = Vega.Web.read(id, cache_dir: c.dir)
    assert Jason.decode!(raw)["output"]["structured"] == %{"fact" => 42}
    assert Jason.decode!(raw)["output"]["grounding"] == [%{"url" => "https://example.org"}]
    assert {:ok, %{status: "completed"}} = Vega.Search.status("test-run", opts)
  end

  test "research timeout and remote failure are events, watcher can be stopped", c do
    opts = [
      api_key: "fake-key",
      base_url: c.url,
      cache_dir: c.dir,
      notify: self(),
      agent: nil,
      poll_interval: 10,
      research_timeout: 50
    ]

    assert {:ok, _} = Vega.Search.watch("pending", opts)
    assert_receive {:vega_research, {:error, %{reason: :research_timeout}}}, 2000
    assert {:ok, _} = Vega.Search.watch("failed", opts)
    assert_receive {:vega_research, {:error, %{reason: :service_failed}}}, 2000

    assert {:ok, watcher} =
             Vega.Search.watch("pending", Keyword.put(opts, :research_timeout, 5000))

    assert Vega.Search.stop_watching(watcher)
    refute_receive {:vega_research, _}, 100
  end

  @tag skip: not File.exists?("/usr/local/bin/lightpanda")
  test "real Lightpanda renders a JavaScript-only document", c do
    assert {:ok, %{text: "", method: "http"}} =
             Vega.Web.fetch(c.url <> "/js", cache_dir: c.dir, javascript: false)

    assert {:ok, %{method: "lightpanda", text: text}} =
             Vega.Web.fetch(c.url <> "/js", cache_dir: c.dir, refresh: true)

    assert String.replace(text, "\\", "") =~ "JS-RENDERED-EVIDENCE"
    assert text =~ "Readable browser content."
  end

  test "JS fallback uses Lightpanda, forced browser and missing binary", c do
    fake = Path.join(c.dir, "fake-lightpanda")
    File.write!(fake, "#!/bin/sh\nprintf 'Rendered JS evidence\\n'\n")
    File.chmod!(fake, 0o700)

    assert {:ok, %{method: "lightpanda", text: "Rendered JS evidence\n"}} =
             Vega.Web.fetch(c.url <> "/shell", cache_dir: c.dir, lightpanda: fake)

    assert {:error, :lightpanda_missing} =
             Vega.Web.render(c.url, lightpanda: "/no/such/lightpanda")

    assert {:ok, %{method: "lightpanda"}} =
             Vega.Web.fetch(c.url <> "/page",
               cache_dir: c.dir,
               lightpanda: fake,
               javascript: true
             )
  end
end
