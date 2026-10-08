defmodule Seedling.SearchTest do
  use ExUnit.Case, async: true
  alias Seedling.{Search, Web}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "atlas-search-test-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      opts: [
        cache_dir: Path.join(root, "cache"),
        jobs_dir: Path.join(root, "jobs"),
        settings: fn "EXA_API_KEY" -> "fake-secret-not-a-real-key" end
      ]
    }
  end

  defp response(data, status \\ 200) do
    {:ok,
     %{
       status: status,
       body: Jason.encode!(data),
       headers: %{"x-request-id" => ["req-1"], "retry-after" => ["3"]}
     }}
  end

  defp fake(data), do: fn _, _, _, _, _ -> response(data) end

  test "search sends compact highlights-only payload; no text leaks into display", %{opts: opts} do
    parent = self()

    transport = fn method, url, headers, body, request_opts ->
      send(parent, {:request, method, url, headers, Jason.decode!(body), request_opts[:redirect]})

      response(%{
        "results" => [
          %{
            "id" => "doc",
            "url" => "https://example.test/a",
            "title" => "Title",
            "highlights" => ["Hit"],
            "text" => "secretly huge body"
          }
        ],
        "costDollars" => %{"total" => 0.01}
      })
    end

    {:ok, result} =
      Search.search(
        "a query",
        opts ++ [transport: transport, limit: 1, params: %{"includeDomains" => ["example.test"]}]
      )

    assert [%{id: "doc", index: 1, title: "Title", highlights: ["Hit"]} = item] = result.results
    refute Map.has_key?(item, :text)
    assert result.request_id == "req-1" and result.cost_dollars["total"] == 0.01
    assert_receive {:request, :post, "https://api.exa.ai/search", headers, payload, false}
    assert headers |> Enum.into(%{}) |> Map.get("x-api-key") == "fake-secret-not-a-real-key"
    assert payload["query"] == "a query" and payload["numResults"] == 1
    assert payload["includeDomains"] == ["example.test"]
    assert payload["contents"] == %{"highlights" => %{"maxCharacters" => 800}}
  end

  test "search bounds highlights, fields, count and full responses page without network", %{
    opts: opts
  } do
    data = %{
      "results" =>
        for(
          n <- 1..100,
          do: %{
            "id" => "#{n}",
            "title" => String.duplicate("日", 200),
            "url" => "https://example.test/#{n}",
            "highlights" => [String.duplicate("h", 5000), "two", "three", "four"]
          }
        )
    }

    {:ok, result} = Search.search("query", opts ++ [transport: fake(data), max_bytes: 1800])
    assert result.truncated and result.notice =~ "Full response"
    assert byte_size(Jason.encode!(result.results)) <= 1800
    assert length(result.results) < 100

    for item <- result.results do
      assert byte_size(item.title) <= 300
      assert byte_size(hd(item.highlights)) <= 800
      assert length(item.highlights) == 3
    end

    {:ok, stored} = Search.read(result.result_id, opts ++ [max_bytes: 100])
    assert stored.truncated and stored.next_offset > 0 and stored.bytes <= 100
    assert stored.total_bytes > 100_000

    {:ok, next} =
      Search.read(result.result_id, opts ++ [offset: stored.next_offset, max_bytes: 100])

    assert next.offset == stored.next_offset
  end

  test "contents stores readable evidence snapshots and announces provider and local cuts", %{
    opts: opts
  } do
    text = "José Valim created Elixir.\n" <> String.duplicate("Content.\n", 2000)

    data = %{
      "results" => [
        %{
          "id" => "https://example.test/author",
          "url" => "https://example.test/author",
          "title" => "Official page",
          "text" => text
        }
      ],
      "statuses" => [%{"id" => "bad", "status" => "error"}]
    }

    {:ok, result} =
      Search.contents(["https://example.test/author"], opts ++ [transport: fake(data)])

    assert result.truncated and result.provider_notice =~ "maxCharacters"
    assert [item] = result.results
    assert byte_size(item.text) <= 6000
    {:ok, readable} = Web.read(item.content_id, opts ++ [max_bytes: 100])
    assert readable.source == "exa-text" and readable.url == "https://example.test/author"
    {:ok, evidence} = Web.evidence(item.content_id, "José Valim created Elixir", opts)
    assert evidence.quote == "José Valim created Elixir"
    assert evidence.url == "https://example.test/author"
    assert {:ok, %{text: raw}} = Search.read(result.result_id, opts ++ [max_bytes: 40_000])
    assert raw =~ "statuses" and raw =~ "content_id"

    {:ok, small} =
      Search.contents(
        ["https://example.test/author"],
        opts ++ [transport: fake(data), max_bytes: 600]
      )

    assert [excerpt] = small.results
    assert excerpt.content_id == item.content_id
    assert byte_size(Jason.encode!(small.results)) <= 600
    assert small.truncated
  end

  test "grounded answer and citation indexes remain bounded and recoverable", %{opts: opts} do
    answer = String.duplicate("Answer 日本語. ", 1000)

    data = %{
      "answer" => answer,
      "citations" => [
        %{
          "url" => "https://example.test/one",
          "title" => "One",
          "text" => String.duplicate("x", 10_000)
        },
        %{"url" => "https://example.test/two", "title" => "Two"}
      ]
    }

    {:ok, result} = Search.answer("question", opts ++ [transport: fake(data), max_bytes: 1000])
    assert result.truncated
    assert byte_size(result.answer) <= 500
    assert [%{index: 1}, %{index: 2}] = result.citations
    refute Map.has_key?(hd(result.citations), :text)
    {:ok, stored} = Search.read(result.result_id, opts ++ [max_bytes: 40_000])
    assert stored.text =~ "Answer 日本語"
  end

  test "missing key, bad key, quota and rate limits are values without secret echoes", %{
    opts: opts
  } do
    assert {:error, %{reason: :missing_key}} =
             Search.search("query", Keyword.put(opts, :settings, fn _ -> nil end))

    for {status, reason} <- [
          {401, :unauthorized},
          {402, :quota},
          {403, :forbidden},
          {429, :rate_limited},
          {500, :http},
          {302, :http}
        ] do
      transport = fn _, _, _, _, _ ->
        response(%{"echo" => "fake-secret-not-a-real-key"}, status)
      end

      {:error, error} = Search.search("query", opts ++ [transport: transport])
      assert error.reason == reason and error.status == status
      assert error.retry_after == "3"
      refute inspect(error) =~ "fake-secret"
    end
  end

  test "invalid JSON, malformed schema, oversized response, timeout and inputs", %{opts: opts} do
    transport = fn _, _, _, _, _ -> {:ok, %{status: 200, body: "not JSON", headers: %{}}} end

    assert {:error, %{reason: :invalid_response}} =
             Search.search("query", opts ++ [transport: transport])

    for data <- [
          %{},
          %{"results" => "bad"},
          %{"results" => [%{"highlights" => "bad"}]},
          %{"results" => [%{"url" => 1}]}
        ] do
      assert {:error, %{reason: :invalid_response}} =
               Search.search("query", opts ++ [transport: fake(data)])
    end

    assert {:error, %{reason: :download_limit}} =
             Search.search(
               "query",
               opts ++ [transport: fake(%{"results" => []}), max_download_bytes: 4]
             )

    assert {:error, %{reason: :timeout}} =
             Search.answer(
               "q",
               opts ++
                 [
                   timeout: 10,
                   transport: fn _, _, _, _, _ ->
                     Process.sleep(500)
                     response(%{})
                   end
                 ]
             )

    for invalid <- [
          [limit: 0],
          [params: nil],
          [max_bytes: 100_000],
          [cache_dir: nil],
          %{timeout: 10},
          [:bad]
        ] do
      assert {:error, %{reason: :invalid_options}} = Search.search("query", invalid)
    end

    assert {:error, %{reason: :invalid_query}} = Search.search("  ", opts)
    assert {:error, %{reason: :invalid_ids}} = Search.contents([], opts)

    assert {:error, %{reason: :invalid_options}} =
             Search.contents(["one"], opts ++ [content_chars: 0])

    assert {:error, %{reason: :invalid_options}} = Search.research("q", %{})
  end

  test "research is unlinked, persists structured output, survives absent/restarted named agent and repeats until ack",
       %{opts: opts, root: root} do
    {:ok, state} = Agent.start_link(fn -> %{recipient: nil, completed: false} end)
    parent = self()

    transport = fn
      :post, url, _, body, _ ->
        assert url == "https://api.exa.ai/agent/runs"
        assert Jason.decode!(body)["effort"] == "minimal"
        response(%{"id" => "run-restart", "status" => "running"})

      :get, _, _, nil, _ ->
        if Agent.get(state, & &1.completed),
          do: response(completed("run-restart")),
          else: response(%{"status" => "running"})
    end

    resolver = fn "test-agent" -> Agent.get(state, & &1.recipient) end

    run_opts =
      opts ++
        [
          transport: transport,
          effort: "minimal",
          poll_interval: 10,
          notify_interval: 15,
          notify: {:agent, "test-agent"},
          agent_resolver: resolver
        ]

    caller =
      spawn(fn ->
        {:ok, job} = Search.research("a narrow question", run_opts)
        send(parent, {:job, job})
        Process.sleep(:infinity)
      end)

    assert_receive {:job, job}, 1000
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, _}
    Agent.update(state, &Map.put(&1, :completed, true))

    assert eventually(fn ->
             match?({:ok, %{"status" => "completed"}}, Search.research_status(job))
           end)

    refute_receive {:forwarded, _}, 20
    replacement = spawn(fn -> forward(parent) end)
    Agent.update(state, &Map.put(&1, :recipient, replacement))
    assert_receive {:forwarded, {:seedling_research, "run-restart", event}}, 1000
    assert event.status == "completed" and is_binary(event.result_id)
    assert_receive {:forwarded, {:seedling_research, "run-restart", _}}, 1000
    assert {:ok, %{acknowledged: true}} = Search.ack_research(job)
    Process.sleep(30)
    flush_events()
    refute_receive {:forwarded, _}, 40
    {:ok, content} = Search.read(event.result_id, opts)
    assert Jason.decode!(content.text)["output"]["structured"] == %{"answer" => "fact"}
    assert content.text =~ "grounding"
    raw = File.read!(Path.join(root, "jobs/run-restart.json"))
    refute raw =~ "fake-secret"
    assert raw =~ "local_complete"
    Process.exit(replacement, :kill)
  end

  test "local watching timeout is actionable and resume polls original id without resubmission",
       %{opts: opts} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    transport = fn
      :post, _, _, _, _ ->
        Agent.update(counter, &(&1 + 1))
        response(%{"id" => "run-timeout", "status" => "running"})

      :get, _, _, _, _ ->
        response(%{"status" => "running"})
    end

    {:ok, job} =
      Search.research("q", opts ++ [transport: transport, research_timeout: 25, poll_interval: 5])

    assert_receive {:seedling_research, "run-timeout",
                    %{status: "error", reason: "timed_out", message: message}},
                   1000

    assert message =~ "remote run"
    {:ok, record} = Search.research_status(job)
    assert record["status"] == "error"
    completed_transport = fn :get, _, _, _, _ -> response(completed("run-timeout")) end
    {:ok, resumed} = Search.resume_research(job, opts ++ [transport: completed_transport])
    assert resumed.id == job.id
    assert_receive {:seedling_research, "run-timeout", %{status: "completed"}}, 1000
    assert Agent.get(counter, & &1) == 1
    Search.ack_research(job)
  end

  test "research transient poll failures retry; terminal failures persist; cancel is explicit", %{
    opts: opts
  } do
    {:ok, polls} = Agent.start_link(fn -> 0 end)
    parent = self()

    transport = fn
      :post, url, _, _, _ ->
        if String.ends_with?(url, "/cancel"), do: send(parent, :cancel_requested)
        response(%{"id" => "run-errors", "status" => "running"})

      :get, _, _, _, _ ->
        if Agent.get_and_update(polls, fn n -> {n, n + 1} end) == 0,
          do: {:ok, %{status: 429, body: "{}", headers: %{}}},
          else: response(%{"status" => "failed", "error" => "remote failed"})
    end

    {:ok, job} = Search.research("q", opts ++ [transport: transport, poll_interval: 5])
    assert_receive {:seedling_research, "run-errors", %{status: "failed", result_id: id}}, 1000
    assert is_binary(id)

    assert {:ok, %{cancellation_requested: true}} =
             Search.cancel_research(job, opts ++ [transport: transport])

    assert_receive :cancel_requested
    assert {:error, %{reason: :invalid_job}} = Search.research_status("../escape", opts)
    assert {:error, %{reason: :invalid_options}} = Search.research("q", opts ++ [effort: "wrong"])
    Search.ack_research(job)
  end

  test "paid run persistence failure returns remote id so it can be recovered or cancelled", %{
    opts: opts,
    root: root
  } do
    blocked = Path.join(root, "blocked")
    File.write!(blocked, "not a directory")

    result =
      Search.research(
        "q",
        Keyword.merge(opts,
          jobs_dir: blocked,
          transport: fake(%{"id" => "run-storage", "status" => "running"})
        )
      )

    assert {:error, %{job: %{id: "run-storage"}, message: message}} = result
    assert message =~ "created" and message =~ "cancel"
  end

  test "resuming persisted completed job delivers without any paid network request", %{opts: opts} do
    {:ok, job} =
      Search.research(
        "q",
        opts ++ [transport: fake(%{"id" => "run-done", "status" => "completed"}), notify: nil]
      )

    assert eventually(fn ->
             match?({:ok, %{"local_complete" => true}}, Search.research_status(job))
           end)

    {:ok, _} =
      Search.resume_research(
        job,
        opts ++ [transport: fn _, _, _, _, _ -> flunk("must not contact Exa") end]
      )

    assert_receive {:seedling_research, "run-done", %{status: "completed"}}, 1000
    Search.ack_research(job)
  end

  defp completed(id),
    do: %{
      "id" => id,
      "status" => "completed",
      "output" => %{
        "structured" => %{"answer" => "fact"},
        "grounding" => [
          %{"field" => "answer", "citations" => [%{"url" => "https://example.test"}]}
        ]
      },
      "costDollars" => %{"total" => 0.012},
      "usage" => %{"searches" => 1}
    }

  defp forward(parent) do
    receive do
      event ->
        send(parent, {:forwarded, event})
        forward(parent)
    end
  end

  defp flush_events do
    receive do
      {:forwarded, _} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp eventually(fun, tries \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, tries),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(fun, tries - 1)
          )
      )
end
