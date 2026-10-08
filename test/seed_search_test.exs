defmodule SeedSearchTest do
  use ExUnit.Case, async: true

  defmodule Handler do
    def init(opts), do: opts

    def call(conn, _) do
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/search" ->
          data = Jason.decode!(body)

          if data["query"] == "rate" do
            conn
            |> Plug.Conn.put_resp_header("retry-after", "2")
            |> Plug.Conn.send_resp(429, "secret-echo")
          else
            unless data["contents"] == %{"highlights" => %{"maxCharacters" => 800}},
              do: raise("wrong contents")

            json(conn, %{
              results:
                List.duplicate(
                  %{
                    id: "x",
                    url: "https://example.com",
                    title: "Example",
                    text: "must not appear",
                    highlights: [String.duplicate("x", 1000)]
                  },
                  if(data["query"] == "many", do: 20, else: 1)
                )
            })
          end

        "/contents" ->
          json(conn, %{
            results: [
              %{url: "https://example.com", title: "Example", text: String.duplicate("z", 20000)}
            ]
          })

        "/answer" ->
          json(conn, %{answer: "An answer", citations: [%{url: "https://example.com"}]})

        "/agent/runs" ->
          json(conn, %{id: "agent_run_test", status: "queued"})

        "/agent/runs/agent_run_test" ->
          json(conn, %{
            id: "agent_run_test",
            status: "completed",
            output: %{content: "done", citations: [%{url: "https://example.com"}]}
          })

        "/agent/runs/agent_run_delayed" ->
          Process.sleep(150)
          json(conn, %{id: "agent_run_delayed", status: "completed", output: %{content: "done"}})

        "/agent/runs/agent_run_wait" ->
          json(conn, %{id: "agent_run_wait", status: "running"})

        "/agent/runs/agent_run_test/cancel" ->
          json(conn, %{status: "cancelled"})

        "/slow" ->
          Process.sleep(200)
          Plug.Conn.send_resp(conn, 200, "ok")

        "/large" ->
          Plug.Conn.send_resp(conn, 200, String.duplicate("x", 20000))

        "/js" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.send_resp(
            200,
            "<html><body><main id='app'></main><script>document.getElementById('app').textContent='Rendered by JavaScript';</script></body></html>"
          )

        "/html" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.send_resp(200, "<main><h1>Cached</h1><p>body</p></main>")
      end
    end

    defp json(conn, data), do: Plug.Conn.send_resp(conn, 200, Jason.encode!(data))
  end

  setup do
    pid = start_supervised!({Bandit, plug: Handler, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    dir = Path.join(System.tmp_dir!(), "seed-search-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok,
     opts: [base_url: "http://127.0.0.1:#{port}", api_key: "fake-test-key", cache_dir: dir],
     base: "http://127.0.0.1:#{port}"}
  end

  test "missing keys and invalid inputs return values" do
    assert {:error, :missing_exa_api_key} = SeedSearch.search("query", api_key: nil)
    assert {:error, :invalid_query_or_limit} = SeedSearch.search("", api_key: nil)
    assert {:error, :invalid_query_or_limit} = SeedSearch.search("q", limit: 21)
    assert {:error, :invalid_run_id} = SeedSearch.resume("../oops")
    assert {:error, :invalid_urls} = SeedSearch.contents([])
    assert {:error, :missing_exa_api_key} = SeedSearch.research("question", api_key: nil)
  end

  test "search is compact and status errors do not echo body", %{opts: opts} do
    assert {:ok, %{results: [result]}} = SeedSearch.search("query", opts)
    assert result.title == "Example"
    refute Map.has_key?(result, :text)
    assert String.ends_with?(hd(result.highlights), "[truncated]")
    assert {:error, %{status: 429, retry_after: ["2"]}} = SeedSearch.search("rate", opts)
  end

  test "contents and answers preserve citations in paged storage", %{opts: opts} do
    assert {:ok, %{pages: [{:ok, page}]}} = SeedSearch.contents(["https://example.com"], opts)
    assert page.truncated
    assert page.total_chars == 20000
    assert {:ok, answer} = SeedSearch.answer("question", opts)
    assert answer.text =~ "https://example.com"
  end

  test "research creates and notifies asynchronously and can cancel", %{opts: opts} do
    assert {:ok, %{pid: pid}} = SeedSearch.research("question", opts ++ [poll_interval: 1])
    assert_receive {:seed_search, ^pid, :started, %{run_id: "agent_run_test"}}, 2000
    assert_receive {:seed_search, ^pid, :completed, result}, 2000
    assert result.page.text =~ "https://example.com"
    assert {:ok, %{"status" => "cancelled"}} = SeedSearch.cancel(result.run_id, opts)

    assert {:ok, %{pid: waiting}} =
             SeedSearch.resume("agent_run_wait", opts ++ [poll_interval: 1, research_timeout: 50])

    assert_receive {:seed_search, ^waiting, :error,
                    %{reason: :research_timeout, run_id: "agent_run_wait"}},
                   2000
  end

  test "HTTP total timeout, body limit and cached HTTP extraction", %{opts: opts, base: base} do
    assert {:error, :timeout} = SeedWeb.HTTP.request(:get, base <> "/slow", nil, [], timeout: 20)

    assert {:error, :body_too_large} =
             SeedWeb.HTTP.request(:get, base <> "/large", nil, [], max_body_bytes: 100)

    assert {:ok, %{text: "Cached\nbody", cached: false}} = SeedWeb.fetch(base <> "/html", opts)
    assert {:ok, %{cached: true}} = SeedWeb.fetch(base <> "/html", opts)
  end

  test "Lightpanda renders local JavaScript and closes its CDP process", %{base: base, opts: opts} do
    if System.find_executable("lightpanda") do
      assert {:error, %{reason: :empty_page}} =
               SeedWeb.fetch(base <> "/js", opts)

      assert {:ok, text} = SeedWeb.Browser.fetch(base <> "/js", timeout: 5000)
      assert text =~ "Rendered by JavaScript"
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(socket)
      :gen_tcp.close(socket)
      assert {:ok, server} = SeedWeb.Browser.serve(port: port)
      on_exit(fn -> SeedWeb.Browser.stop(server.pid) end)
      Process.sleep(100)

      assert {:ok, %{status: 200}} =
               SeedWeb.HTTP.request(:get, server.endpoint <> "/json/version", nil, [],
                 timeout: 2000
               )

      SeedWeb.Browser.stop(server.pid)
      ref = Process.monitor(server.pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2000
      Process.sleep(100)

      assert {:error, _} =
               SeedWeb.HTTP.request(:get, server.endpoint <> "/json/version", nil, [],
                 timeout: 200
               )
    end
  end

  test "aggregate search output is bounded and full response is recoverable", %{opts: opts} do
    assert {:ok, result} = SeedSearch.search("many", opts ++ [limit: 20])
    assert result.truncated
    assert length(result.results) < 20
    assert byte_size(inspect(result, limit: :infinity, printable_limit: :infinity)) < 17000
    assert {:ok, full} = SeedWeb.read(result.content_id, opts)
    assert full.truncated
    assert full.text =~ "must not appear"
  end

  test "default owner outlives launching eval task for research and resume", %{opts: opts} do
    parent = self()

    launcher =
      spawn(fn ->
        Process.put(:"$callers", [parent])
        result = SeedSearch.research("question", opts)
        send(parent, {:launched, self(), result})
      end)

    assert_receive {:launched, ^launcher, {:ok, %{pid: job_pid}}}, 2000
    ref = Process.monitor(launcher)
    assert_receive {:DOWN, ^ref, :process, ^launcher, _}, 2000
    assert_receive {:seed_search, ^job_pid, :started, %{run_id: "agent_run_test"}}, 2000
    assert_receive {:seed_search, ^job_pid, :completed, _}, 2000
    assert {:ok, record} = SeedSearch.job("agent_run_test", opts)
    assert record["status"] == "completed"
    assert is_binary(record["content_id"])
    assert {:ok, %{jobs: [stored]}} = SeedSearch.jobs(opts)
    assert stored["run_id"] == "agent_run_test"
    assert {:error, :invalid_job_limit} = SeedSearch.jobs(opts ++ [limit: 0])

    spawn(fn ->
      Process.put(:"$callers", [parent])
      send(parent, {:resumed, SeedSearch.resume("agent_run_delayed", opts)})
    end)

    assert_receive {:resumed, {:ok, %{pid: resumed_pid}}}, 2000
    assert_receive {:seed_search, ^resumed_pid, :completed, _}, 2000
  end

  test "named owner resolves at event time, including after replacement", %{opts: opts} do
    parent = self()
    name = "seed-search-owner-#{System.unique_integer([:positive])}"

    first =
      spawn(fn ->
        receive do
          event -> send(parent, {:first_owner, event})
        end

        receive do
          :stop -> :ok
        end
      end)

    second =
      spawn(fn ->
        receive do
          event -> send(parent, {:second_owner, event})
        end
      end)

    assert :yes = Nano.Names.register_name({:agent, name}, first)

    on_exit(fn ->
      Nano.Names.unregister_name({:agent, name})
      Process.exit(first, :kill)
      Process.exit(second, :kill)
    end)

    # No new provider task: resume an existing fake run and replace owner while poll waits.
    {:ok, %{pid: pid}} = SeedSearch.resume("agent_run_delayed", opts ++ [owner: name])
    Nano.Names.unregister_name({:agent, name})
    assert :yes = Nano.Names.register_name({:agent, name}, second)
    send(first, :stop)
    assert_receive {:second_owner, {:seed_search, ^pid, :completed, _}}, 2000
    refute_receive {:first_owner, {:seed_search, ^pid, _, _}}, 20
    assert {:ok, %{"owner" => ^name}} = SeedSearch.job("agent_run_delayed", opts)
  end

  test "missing named owner still leaves durable result and credentials are not recorded", %{
    opts: opts
  } do
    {:ok, %{pid: pid}} =
      SeedSearch.resume(
        "agent_run_test",
        opts ++ [owner: "missing-#{System.unique_integer([:positive])}"]
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    assert {:ok, record} = SeedSearch.job("agent_run_test", opts)
    refute Jason.encode!(record) =~ "fake-test-key"
    assert record["status"] == "completed"
    blocked = Path.join(opts[:cache_dir], "blocked")
    File.write!(blocked, "not a directory")
    assert {:error, _} = SeedSearch.research("question", opts ++ [job_dir: blocked])
  end
end
