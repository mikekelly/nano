defmodule Seedling.SearchTest do
  use ExUnit.Case, async: true
  alias Seedling.Search
  alias Seedling.Web
  alias Seedling.WebFixture, as: Fixture

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "orion-search-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{opts: [cache_dir: dir, api_key: "fixture-not-a-real-key", timeout: 1000]}
  end

  defp server(handler, opts) do
    {pid, base} = Fixture.start(handler)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    Keyword.put(opts, :base_url, base)
  end

  test "missing key is honest and makes no request", %{opts: opts} do
    owner = self()

    opts =
      server(
        fn conn ->
          send(owner, :unexpected)
          Fixture.json(conn, 200, %{})
        end,
        opts
      )

    opts = Keyword.put(opts, :api_key, nil)
    assert {:error, %{kind: :missing_key}} = Search.search("query", opts)
    assert {:error, %{kind: :missing_key}} = Search.contents(["url"], opts)
    assert {:error, %{kind: :missing_key}} = Search.answer("query", opts)
    assert {:error, %{kind: :missing_key}} = Search.research("query", opts)
    refute_receive :unexpected, 20
  end

  test "search contract: no full text request or result and bounded metadata", %{opts: opts} do
    owner = self()

    opts =
      server(
        fn conn ->
          {body, conn} = Fixture.body(conn)

          send(
            owner,
            {:request, conn.request_path, body, Plug.Conn.get_req_header(conn, "x-api-key")}
          )

          Fixture.json(conn, 200, %{
            "results" =>
              List.duplicate(
                %{
                  "id" => "https://source.test",
                  "url" => "https://source.test",
                  "title" => String.duplicate("t", 800),
                  "highlights" => [String.duplicate("h", 1000)],
                  "text" => String.duplicate("not included", 5000)
                },
                6
              )
          })
        end,
        opts
      )

    assert {:ok, %{results: results}} = Search.search("query", opts ++ [num_results: 2])
    assert length(results) == 2

    assert_receive {:request, "/search", %{"contents" => %{"text" => false}, "numResults" => 2},
                    ["fixture-not-a-real-key"]}

    assert byte_size(hd(results).title) == 300
    assert byte_size(hd(hd(results).highlights)) == 500
    refute Map.has_key?(hd(results), :text)
    assert {:error, %{kind: :invalid_limit}} = Search.search("query", opts ++ [num_results: 99])
    assert {:error, %{kind: :invalid_query}} = Search.search(" ", opts)
  end

  test "contents caches long text, reports partial failure, read and cite later", %{opts: opts} do
    opts =
      server(
        fn conn ->
          {body, conn} = Fixture.body(conn)
          assert body["ids"] == ["https://source.test"]

          Fixture.json(conn, 200, %{
            "results" => [
              %{
                "id" => "https://source.test",
                "url" => "https://source.test",
                "title" => "Source",
                "text" => String.duplicate("source ", 3000)
              }
            ],
            "statuses" => [
              %{"id" => "other", "status" => "error", "error" => %{"message" => "not leaked"}}
            ]
          })
        end,
        opts
      )

    assert {:ok, %{results: [result], statuses: [%{"status" => "error"} = status]}} =
             Search.contents(["https://source.test"], opts)

    refute Map.has_key?(result, :text)
    refute Map.has_key?(status, "error")
    assert {:ok, %{text: text, truncated: true}} = Web.read(result.cache_id, opts ++ [limit: 100])
    assert String.length(text) == 100
    assert {:ok, %{url: "https://source.test"}} = Web.cite(result.cache_id, opts)
  end

  test "answer keeps citations and stores full JSON when answer is sliced", %{opts: opts} do
    opts =
      server(
        fn conn ->
          Fixture.json(conn, 200, %{
            "answer" => String.duplicate("answer ", 3000),
            "citations" => [
              %{
                "url" => "https://source.test",
                "title" => "Source",
                "text" => String.duplicate("huge", 5000)
              }
            ]
          })
        end,
        opts
      )

    assert {:ok,
            %{
              answer: answer,
              truncated: true,
              citations: [%{url: "https://source.test"}],
              cache_id: id
            }} = Search.answer("query", opts)

    assert byte_size(answer) == 8000
    assert {:ok, %{truncated: true}} = Web.read(id, opts)
  end

  test "provider errors are sanitized values, with retry timing, never secret-bearing body", %{
    opts: opts
  } do
    for {status, kind} <- [
          {401, :unauthorized},
          {402, :payment_required},
          {403, :forbidden},
          {429, :rate_limited},
          {503, :service_unavailable}
        ] do
      local =
        server(
          fn conn ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "2")
            |> Fixture.json(status, %{"error" => "fixture-not-a-real-key"})
          end,
          opts
        )

      assert {:error, %{kind: ^kind, status: ^status, retry_after_ms: 2000} = error} =
               Search.search("query", local)

      refute inspect(error) =~ "fixture-not-a-real-key"
    end
  end

  test "invalid JSON responses and validation", %{opts: opts} do
    opts = server(fn conn -> Fixture.text(conn, "not-json", "application/json") end, opts)
    assert {:error, %{kind: :invalid_response}} = Search.search("query", opts)
    assert {:error, %{kind: :invalid_run_id}} = Search.watch("../secret", opts)
    assert {:error, %{kind: :invalid_ids}} = Search.contents([], opts)
  end

  test "research posts current API schema and notifies later with structured output cached", %{
    opts: opts
  } do
    owner = self()
    {:ok, count} = Agent.start_link(fn -> 0 end)
    schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

    opts =
      server(
        fn conn ->
          if conn.method == "POST" do
            {body, conn} = Fixture.body(conn)
            send(owner, {:create, conn.request_path, body})

            Fixture.json(conn, 201, %{
              "id" => "agent_run_test",
              "status" => "running",
              "output" => nil
            })
          else
            n = Agent.get_and_update(count, fn n -> {n, n + 1} end)

            Fixture.json(conn, 200, %{
              "id" => "agent_run_test",
              "status" => if(n == 0, do: "running", else: "completed"),
              "output" => %{
                "text" => "done",
                "structured" => %{"answer" => "yes"},
                "grounding" => [%{"url" => "https://source.test"}]
              }
            })
          end
        end,
        opts
      ) ++ [poll_interval: 10, max_wait: 1000, output_schema: schema]

    assert {:ok, run} = Search.research("research query", opts)
    assert run.run_id == "agent_run_test" and is_pid(run.worker)
    assert_receive {:create, "/agent/runs", %{"effort" => "minimal", "outputSchema" => ^schema}}

    assert_receive %{
                     event: :seedling_research,
                     run_id: "agent_run_test",
                     result: {:ok, %{status: "completed"}}
                   },
                   1000

    assert {:ok, page} = Search.research_read(run.run_id, opts)
    data = Jason.decode!(page.text)
    assert data["output"]["structured"] == %{"answer" => "yes"}
    assert data["output"]["grounding"] != []
  end

  test "watch resumes existing run without paid creation and preserves failed/cancelled status",
       %{opts: opts} do
    for status <- ["failed", "cancelled"] do
      local =
        server(
          fn conn ->
            assert conn.method == "GET"
            Fixture.json(conn, 200, %{"id" => "resume_" <> status, "status" => status})
          end,
          opts
        ) ++ [poll_interval: 1]

      assert {:ok, _} = Search.watch("resume_" <> status, local)
      assert_receive %{event: :seedling_research, result: {:ok, %{status: ^status}}}, 500
    end
  end

  test "research timeout is explicit, and owner death stops local watcher", %{opts: opts} do
    opts =
      server(
        fn conn -> Fixture.json(conn, 200, %{"id" => "waiting", "status" => "running"}) end,
        opts
      ) ++ [poll_interval: 10, max_wait: 30]

    {:ok, run} = Search.watch("waiting", opts)
    assert_receive %{event: :seedling_research, result: {:error, %{kind: :research_timeout}}}, 500
    refute Process.alive?(run.worker)
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, run} = Search.watch("waiting", Keyword.put(opts, :notify, owner))
    monitor = Process.monitor(run.worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, _, _, :normal}, 500
  end

  test "research transient service error retries then completes", %{opts: opts} do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    opts =
      server(
        fn conn ->
          n = Agent.get_and_update(count, fn n -> {n, n + 1} end)

          if n == 0,
            do: conn |> Plug.Conn.put_resp_header("retry-after", "0") |> Fixture.json(429, %{}),
            else: Fixture.json(conn, 200, %{"id" => "retry", "status" => "completed"})
        end,
        opts
      ) ++ [poll_interval: 1, max_wait: 1000]

    {:ok, _} = Search.watch("retry", opts)
    assert_receive %{event: :seedling_research, result: {:ok, %{status: "completed"}}}, 1000
    assert Agent.get(count, & &1) == 2
  end

  test "cancel addresses service cancellation endpoint", %{opts: opts} do
    opts =
      server(
        fn conn ->
          assert conn.request_path == "/agent/runs/cancel_me/cancel"
          assert conn.method == "POST"
          Fixture.json(conn, 200, %{"id" => "cancel_me", "status" => "cancelled"})
        end,
        opts
      )

    assert {:ok, %{status: "cancelled"}} = Search.cancel("cancel_me", opts)
  end
end
