defmodule Seedling.WebTest do
  use ExUnit.Case, async: true
  alias Seedling.Web

  setup do
    dir = Path.join(System.tmp_dir!(), "web-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, opts: [cache_dir: dir, render: false]}
  end

  test "HTTP fetch persists and pages UTF-8 with explicit byte cursors", %{opts: opts} do
    http = fn _, _ -> {:ok, String.duplicate("é", 40), "text/plain"} end
    {:ok, first} = Web.fetch("https://example.test/", opts ++ [http: http, bytes: 5])
    assert first.text == "éé"
    assert first.next_offset == 4
    assert first.more
    refute first.cached
    assert {:error, :offset_not_utf8_boundary} = Web.read(first.id, opts ++ [offset: 1])
    {:ok, second} = Web.read(first.id, opts ++ [offset: 4, bytes: 5])
    assert second.text == "éé"

    {:ok, cached} =
      Web.fetch("https://example.test/", opts ++ [http: fn _, _ -> flunk("cache miss") end])

    assert cached.cached
    assert {:ok, %{quote: "éé", byte_offset: 0}} = Web.evidence(first.id, "éé", opts)
    assert {:error, :passage_not_found} = Web.evidence(first.id, "missing", opts)
  end

  test "real curl handles local HTTP, errors and size limits", %{opts: opts} do
    assert {:ok, %{text: "hello", rendered: false}} = Web.fetch(endpoint("200 OK", "hello"), opts)
    assert {:error, {:http_failed, 22, _}} = Web.fetch(endpoint("404 Not Found", "absent"), opts)
    assert {:error, {:http_failed, 63, _}} = Web.fetch(endpoint("200 OK", "", 2_000_001), opts)
    assert {:error, :unsupported_text_encoding} = Web.fetch(endpoint("200 OK", <<255>>), opts)
  end

  defp endpoint(status, body, length \\ nil) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    worker =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 5000) do
          :gen_tcp.recv(socket, 0, 5000)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status}\r\nContent-Type: text/plain\r\nContent-Length: #{length || byte_size(body)}\r\nConnection: close\r\n\r\n" <>
              body
          )

          :gen_tcp.close(socket)
        end

        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(worker, :kill)
    end)

    "http://127.0.0.1:#{port}/"
  end

  test "extracts main content
 without scripts and navigation" do
    assert Web.extract(
             "<nav>noise</nav><main><h1>Title</h1><script>bad()</script><p>A &amp; B</p></main>"
           ) == "Title\nA & B"
  end

  test "automatic and explicit JS rendering", %{opts: opts} do
    opts = Keyword.put(opts, :render, :auto)

    {:ok, page} =
      Web.fetch(
        "https://example.test/js",
        opts ++
          [
            http: fn _, _ -> {:ok, "<div>Loading</div>", "text/html"} end,
            renderer: fn _, _ -> {:ok, "Rendered content"} end
          ]
      )

    assert page.rendered
    assert page.text == "Rendered content"

    assert {:error, :offline} =
             Web.fetch(
               "https://example.test/error",
               Keyword.put(opts, :render, true) ++ [renderer: fn _, _ -> {:error, :offline} end]
             )
  end

  test "invalid URL, missing cache, binary/PDF and transport errors", %{opts: opts} do
    assert {:error, _} = Web.fetch("file:///etc/passwd", opts)
    assert {:error, _} = Web.read("../secret", opts)
    assert {:error, :enoent} = Web.read(String.duplicate("a", 64), opts)

    assert {:error, {:unsupported_content_type, "application/pdf"}} =
             Web.fetch(
               "https://example.test/pdf",
               opts ++ [http: fn _, _ -> {:ok, "%PDF data", "application/pdf"} end]
             )

    assert {:error, :timeout} =
             Web.fetch(
               "https://example.test/slow",
               opts ++ [http: fn _, _ -> {:error, :timeout} end]
             )
  end

  test "page cap, end offsets and short plaintext does not trigger render", %{opts: opts} do
    opts = Keyword.put(opts, :render, :auto)

    {:ok, page} =
      Web.fetch(
        "https://example.test/large",
        opts ++
          [http: fn _, _ -> {:ok, String.duplicate("x", 40000), "text/plain"} end, bytes: 999_999]
      )

    assert byte_size(page.text) == 24000
    assert page.more
    refute page.rendered
    assert {:ok, %{text: "", more: false}} = Web.read(page.id, opts ++ [offset: 40000])
    assert {:error, {:invalid_offset, 40000}} = Web.read(page.id, opts ++ [offset: 40001])

    assert {:ok, %{rendered: false}} =
             Web.fetch(
               "https://example.test/short",
               opts ++
                 [
                   http: fn _, _ -> {:ok, "short", "text/plain"} end,
                   renderer: fn _, _ -> flunk("render invoked") end
                 ]
             )
  end

  test "refresh replaces durable
 cache and old cache expires",
       %{opts: opts} do
    url = "https://example.test/refresh"
    {:ok, page} = Web.fetch(url, opts ++ [http: fn _, _ -> {:ok, "old", "text/plain"} end])

    {:ok, new} =
      Web.fetch(url, opts ++ [refresh: true, http: fn _, _ -> {:ok, "new", "text/plain"} end])

    assert new.id == page.id
    assert new.text == "new"
    path = Path.join(opts[:cache_dir], page.id <> ".cache")
    doc = path |> File.read!() |> :erlang.binary_to_term()
    File.write!(path, :erlang.term_to_binary(%{doc | fetched_at: 0}))
    assert {:error, :expired} = Web.read(page.id, opts)
  end
end
