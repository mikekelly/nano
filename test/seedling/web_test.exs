defmodule Seedling.WebTest do
  use ExUnit.Case, async: true
  alias Seedling.Web
  alias Seedling.Web.{HTTP, Store}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "atlas-web-test-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      opts: [cache_dir: Path.join(root, "cache"), spool_dir: Path.join(root, "spool")]
    }
  end

  defp http(text, type \\ "text/plain", status \\ 200) do
    fn _, _, _, _, _ ->
      {:ok, %{status: status, body: text, headers: %{"content-type" => [type]}}}
    end
  end

  test "HTTP-first semantic extraction keeps multiple sections, links and citation hashes", %{
    opts: opts
  } do
    para = String.duplicate("Purposeful readable text &amp; data. ", 12)

    html =
      "<html><title>A &amp; B</title><body><nav>noise</nav><script>danger()</script><article><h1>One</h1><p>#{para}</p><a href='/help'>Help</a></article><article><h2>Two</h2><p>#{para}</p></article></body></html>"

    {:ok, page} =
      Web.fetch("https://example.test/page", opts ++ [transport: http(html, "text/html")])

    assert page.source == "http-html"
    assert page.title == "A & B"
    assert page.text =~ "# One"
    assert page.text =~ "## Two"
    assert page.text =~ "[Help](https://example.test/help)"
    refute page.text =~ "noise"
    refute page.text =~ "danger"
    {:ok, evidence} = Web.evidence(page.id, "purposeful readable text", opts)
    assert evidence.url == "https://example.test/page"
    assert evidence.sha256 == page.sha256
    assert evidence.quote == "Purposeful readable text"
    assert evidence.end_offset - evidence.offset == byte_size(evidence.quote)
    assert evidence.citation =~ page.url

    {:ok, same} =
      Web.read(page.id, opts ++ [offset: evidence.offset, max_bytes: byte_size(evidence.quote)])

    assert same.text == evidence.quote
  end

  test "UTF-8 pagination reconstructs exact original text and announces every cut", %{opts: opts} do
    text = String.duplicate("日本語 José 🚀\n", 20)

    {:ok, page} =
      Web.fetch("https://example.test/text", opts ++ [transport: http(text), max_bytes: 31])

    assert page.bytes <= 31
    assert page.truncated and page.notice =~ "offset"
    assert page.next_offset == byte_size(page.text)
    assert collect(page, opts ++ [max_bytes: 31]) == text
    assert {:error, %{reason: :offset}} = Web.read(page.id, opts ++ [offset: 1])
    assert {:error, %{reason: :offset}} = Web.read(page.id, opts ++ [offset: byte_size(text) + 1])

    assert {:ok, %{text: "", truncated: false}} =
             Web.read(page.id, opts ++ [offset: byte_size(text)])
  end

  defp collect(%{next_offset: nil, text: text}, _opts), do: text

  defp collect(page, opts) do
    {:ok, next} = Web.read(page.id, Keyword.put(opts, :offset, page.next_offset))
    page.text <> collect(next, opts)
  end

  test "cache reuse, forced refresh and expiry do not masquerade as network calls", %{opts: opts} do
    parent = self()

    transport = fn _, _, _, _, _ ->
      send(parent, :network)
      {:ok, %{status: 200, body: "hello", headers: %{}}}
    end

    {:ok, first} = Web.fetch("https://example.test/cache", opts ++ [transport: transport])
    assert_receive :network
    {:ok, second} = Web.fetch("https://example.test/cache", opts ++ [transport: transport])
    assert second.cached and first.id == second.id
    refute_receive :network, 20

    {:ok, _} =
      Web.fetch("https://example.test/cache", opts ++ [transport: transport, refresh: true])

    assert_receive :network

    {:ok, _} =
      Web.fetch("https://example.test/cache", opts ++ [transport: transport, cache_ttl: 0])

    assert_receive :network
  end

  test "cache retains at most configured snapshots", %{opts: opts} do
    {:ok, old} =
      Web.fetch("https://example.test/one", opts ++ [transport: http("one"), cache_entries: 1])

    {:ok, fresh} =
      Web.fetch("https://example.test/two", opts ++ [transport: http("two"), cache_entries: 1])

    assert {:error, %{reason: :cache_miss}} = Web.read(old.id, opts)
    assert {:ok, %{text: "two"}} = Web.read(fresh.id, opts)
    assert length(Path.wildcard(Path.join(opts[:cache_dir], "*.json"))) == 1
  end

  test "browser fallback for a JS shell is spooled, bounded and shell quoted", %{
    opts: opts,
    root: root
  } do
    spool = Path.join(root, "rendered.md")
    text = String.duplicate("Rendered JavaScript page 日本語.\n", 100)
    File.write!(spool, text)
    parent = self()

    shell = fn command, shell_opts ->
      send(parent, {:browser, command, shell_opts})
      {:ok, %{status: :exited, exit_code: 0, bytes: byte_size(text), output_path: spool}}
    end

    {:ok, page} =
      Web.fetch(
        "https://example.test/'quoted",
        opts ++
          [
            transport: http("<html><body><div id='app'></div></body></html>", "text/html"),
            shell: shell,
            max_bytes: 100
          ]
      )

    assert page.source == "lightpanda" and page.truncated
    assert page.bytes <= 100
    assert_receive {:browser, command, shell_opts}
    assert command =~ "'\\''"
    assert shell_opts[:timeout] <= 20_000

    assert {:error, %{reason: :javascript_required}} =
             Web.fetch(
               "https://example.test/shell",
               opts ++ [mode: :http, transport: http("<html><body></body></html>", "text/html")]
             )
  end

  test "unsupported binary and PDF do not launch the browser", %{opts: opts} do
    shell = fn _, _ -> flunk("should not launch") end

    for {text, type} <- [
          {"%PDF-1.0", "application/pdf"},
          {<<0, 255>>, "application/octet-stream"},
          {"a,b", "application/zip"}
        ] do
      assert {:error, %{reason: :unsupported_format}} =
               Web.fetch(
                 "https://example.test/file",
                 opts ++ [transport: http(text, type), shell: shell]
               )
    end
  end

  test "download and browser caps/error/timeout are explicit", %{opts: opts, root: root} do
    assert {:error, %{reason: :download_limit}} =
             Web.fetch(
               "https://example.test/big",
               opts ++ [transport: http(String.duplicate("x", 50)), max_download_bytes: 10]
             )

    for {status, exit_code, reason} <- [{:timeout, nil, :timeout}, {:exited, 2, :browser_failed}] do
      shell = fn _, _ ->
        {:ok, %{status: status, exit_code: exit_code, bytes: 0, output_path: "not-here"}}
      end

      assert {:error, %{reason: ^reason}} =
               Web.fetch("https://example.test/browser", opts ++ [mode: :browser, shell: shell])
    end

    spool = Path.join(root, "big.md")
    File.write!(spool, "big")
    shell = fn _, _ -> {:ok, %{status: :exited, exit_code: 0, bytes: 100, output_path: spool}} end

    assert {:error, %{reason: :download_limit}} =
             Web.fetch(
               "https://example.test/browser",
               opts ++ [mode: :browser, shell: shell, max_download_bytes: 10]
             )
  end

  test "transport deadline kills stalled worker and exceptions are values", %{opts: opts} do
    transport = fn _, _, _, _, _ ->
      Process.sleep(1000)
      flunk("deadline did not kill")
    end

    assert {:error, %{reason: :timeout}} =
             Web.fetch(
               "https://example.test/slow",
               opts ++ [mode: :http, transport: transport, timeout: 10]
             )

    assert {:error, %{reason: :transport}} =
             Web.fetch(
               "https://example.test/fail",
               opts ++ [mode: :http, transport: fn _, _, _, _, _ -> raise "private detail" end]
             )

    assert {:error, %{reason: :http}} =
             Web.fetch(
               "https://example.test/404",
               opts ++ [mode: :http, transport: http("not found", "text/plain", 404)]
             )
  end

  test "invalid URLs, options, ids, encoding and evidence miss are actionable", %{opts: opts} do
    for url <- [nil, "file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.com"] do
      assert {:error, %{reason: :invalid_url}} = Web.fetch(url, opts)
    end

    for invalid <- [
          [max_bytes: 0],
          [mode: :bad],
          [timeout: -1],
          [cache_dir: nil],
          [cache_entries: 0],
          [max_download_bytes: -1],
          %{mode: :http},
          [:bad]
        ] do
      assert {:error, %{reason: :invalid_options}} = Web.fetch("https://example.test", invalid)
    end

    assert {:error, %{reason: :invalid_id}} = Web.read("../secret", opts)
    assert {:error, %{reason: :cache_miss}} = Web.read(String.duplicate("a", 64), opts)

    {:ok, page} =
      Web.fetch("https://example.test/evidence", opts ++ [transport: http("The quick brown fox")])

    assert {:error, %{reason: :not_found}} = Web.evidence(page.id, "slow fox", opts)
    assert {:error, %{reason: :invalid_options}} = Web.evidence(page.id, <<255>>, opts)
    {:ok, evidence} = Web.evidence(page.id, "quick brown", opts ++ [max_bytes: 4])
    assert evidence.quote == "quic" and evidence.truncated and evidence.notice != nil
  end

  test "real HTTP stream stops oversized content without returning a partial success" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.recv(socket, 0, 1000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10000\r\nConnection: close\r\n\r\n" <>
            String.duplicate("x", 10000)
        )

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    assert {:error, %{reason: :download_limit}} =
             HTTP.request(:get, "http://127.0.0.1:#{port}", [], nil, max_download_bytes: 10)
  end

  test "CDP port conflict is an error; helpers do not claim interactive automation" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    assert {:error, %{reason: :port_in_use}} = Web.browser(port: port)
    :gen_tcp.close(listener)
    assert {:error, %{reason: :invalid_options}} = Web.browser(port: 0)
    assert {:error, %{reason: :invalid_browser}} = Web.stop_browser(nil)
    assert Store.clip("日本語", 4) == "日"
  end
end
