defmodule Nano.WebSearchTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "nova-web-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{opts: [cache_dir: dir]}
  end

  defp mock(body, status \\ 200, type \\ "application/json") do
    [
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type(type)
        |> Plug.Conn.send_resp(status, if(is_binary(body), do: body, else: Jason.encode!(body)))
      end
    ]
  end

  test "HTML extraction, cache and paged citation", %{opts: opts} do
    opts =
      opts ++
        [
          req_options:
            mock(
              "<script>bad</script><nav>menu</nav><h1>Hello</h1><p>World &amp; me</p>",
              200,
              "text/html"
            ),
          limit: 1
        ]

    assert {:ok, p} = Nano.Web.fetch("https://example.org", opts)
    assert p.text == "1: Hello"
    assert p.next_offset == 2
    assert {:ok, next} = Nano.Web.read(p.id, Keyword.put(opts, :offset, 3))
    assert next.text == "3: World & me"

    assert {:ok, ^p} =
             Nano.Web.fetch(
               "https://example.org",
               Keyword.put(opts, :req_options, mock("fail", 500))
             )
  end

  test "bounded output and oversized lines", %{opts: opts} do
    assert {:ok, p} = Nano.Web.store("https://example.org", "one\ntwo\nthree", opts ++ [limit: 1])
    assert p.truncated
    assert {:error, {:invalid_offset, 3}} = Nano.Web.read(p.id, opts ++ [offset: 4])

    assert {:error, {:line_too_large, 1, 100}} =
             Nano.Web.store("x", String.duplicate("a", 100), opts ++ [max_bytes: 20])

    assert {:error, :invalid_id} = Nano.Web.read("../../etc/passwd")
    assert {:error, :invalid_url} = Nano.Web.fetch("file:///etc/passwd")
  end

  test "HTTP failures and unsupported binary", %{opts: opts} do
    assert {:error, {:http_status, 404}} =
             Nano.Web.fetch("https://example.org/404", opts ++ [req_options: mock("no", 404)])

    assert {:error, :pdf_not_supported} =
             Nano.Web.fetch(
               "https://example.org/pdf",
               opts ++ [req_options: mock("pdf", 200, "application/pdf")]
             )
  end

  test "compact search and errors" do
    r = %{
      "results" => [
        %{
          "id" => "a",
          "url" => "https://a",
          "title" => "A",
          "text" => String.duplicate("x", 50_000),
          "highlights" => ["evidence"]
        }
      ]
    }

    assert {:ok, %{results: [result]}} =
             Nano.Search.search("query", api_key: "test", req_options: mock(r))

    refute Map.has_key?(result, :text)
    assert result.highlights == ["evidence"]
    assert {:error, :missing_api_key} = Nano.Search.search("q", api_key: nil)

    assert {:error, %{status: 429}} =
             Nano.Search.search("q", api_key: "test", req_options: mock(%{}, 429))
  end

  test "contents and answer", %{opts: opts} do
    r = %{
      "results" => [
        %{"id" => "https://a", "url" => "https://a", "text" => "citation", "title" => "A"}
      ]
    }

    assert {:ok, %{results: [%{page: p}]}} =
             Nano.Search.contents("https://a", opts ++ [api_key: "test", req_options: mock(r)])

    assert p.text == "1: citation"

    assert {:ok, %{answer: "yes", citations: [%{url: "https://a"}]}} =
             Nano.Search.answer("q",
               api_key: "test",
               req_options: mock(%{"answer" => "yes", "citations" => [%{"url" => "https://a"}]})
             )
  end

  test "research sends completion event and stored results", %{opts: opts} do
    plug = fn conn ->
      body =
        if conn.method == "POST",
          do: %{"id" => "run-1", "status" => "queued"},
          else: %{"id" => "run-1", "status" => "completed", "output" => %{"answer" => "result"}}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    assert {:ok, %{ref: ref}} =
             Nano.Search.research("q", opts ++ [api_key: "test", req_options: [plug: plug]])

    assert_receive {:nano_research_started, ^ref, "run-1"}, 2000
    assert_receive {:nano_research, ^ref, {:ok, %{id: "run-1", page: p}}}, 2000
    assert p.text =~ "result"
  end

  test "research deadline returns recoverable id" do
    assert {:ok, %{ref: ref}} =
             Nano.Search.research("q",
               api_key: "test",
               research_timeout: 0,
               req_options: mock(%{"id" => "r"})
             )

    assert_receive {:nano_research, ^ref, {:error, %{reason: :research_timeout, id: "r"}}}, 2000
  end

  test "cache pruning and refresh", %{opts: opts} do
    for n <- 1..4,
        do: Nano.Web.store("https://example.org/#{n}", "page #{n}", opts ++ [cache_entries: 2])

    assert length(Path.wildcard(Path.join(opts[:cache_dir], "*.json"))) == 2

    assert {:ok, first} =
             Nano.Web.fetch(
               "https://example.org/fresh",
               opts ++ [req_options: mock("first", 200, "text/plain")]
             )

    assert {:ok, second} =
             Nano.Web.fetch(
               "https://example.org/fresh",
               opts ++ [refresh: true, req_options: mock("second", 200, "text/plain")]
             )

    assert first.id == second.id
    assert second.text == "1: second"
  end

  test "research polling and failed run", %{opts: opts} do
    plug = fn conn ->
      body =
        if conn.method == "POST",
          do: %{"id" => "run-fail"},
          else: %{"id" => "run-fail", "status" => "failed"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    assert {:ok, %{ref: ref}} =
             Nano.Search.research("q", opts ++ [api_key: "test", req_options: [plug: plug]])

    assert_receive {:nano_research, ^ref, {:error, %{reason: "failed", id: "run-fail"}}}, 2000
  end

  test "browser missing and shell-free URL validation" do
    assert {:error, :lightpanda_missing} =
             Nano.Lightpanda.fetch("https://example.org", executable: nil)

    assert {:error, :invalid_url} = Nano.Lightpanda.fetch("--help")
  end
end
