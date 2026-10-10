defmodule Nano.SearchTest do
  use ExUnit.Case, async: true
  alias Nano.Search

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "altair-search-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "search defaults compact highlights, no full text", %{dir: dir} do
    caller = self()

    fake = fn :post, "/search", body ->
      send(caller, body)

      {:ok, 200, %{},
       %{
         "results" => [
           %{
             "id" => "id",
             "title" => "Title",
             "url" => "https://example.org",
             "text" => "HUGE",
             "highlights" => ["Evidence"]
           }
         ]
       }}
    end

    assert {:ok, r} = Search.search("topic", transport: fake, dir: dir)
    assert_receive %{"numResults" => 10, "contents" => %{"highlights" => _}}
    refute r.text =~ "HUGE"
    assert r.text =~ "Evidence"
    assert {:ok, %{text: text}} = Search.read(r.result)
    assert text =~ "https://example.org"
  end

  test "content is paged, Unicode byte bounds and citations survive", %{dir: dir} do
    fake = fn :post, "/contents", %{"urls" => [_], "text" => %{"maxCharacters" => 30000}} ->
      {:ok, 200, %{},
       %{"results" => [%{"text" => String.duplicate("é", 2000), "url" => "https://example.org"}]}}
    end

    assert {:ok, r} =
             Search.contents(["https://example.org"], transport: fake, dir: dir, max_bytes: 101)

    assert r.cut
    assert byte_size(r.text) <= 101
    assert String.valid?(r.text)
    assert r.continuation =~ "read"
    assert {:ok, %{text: text}} = Search.read(r.result, max_bytes: 10000)
    assert text =~ "https://example.org"
  end

  test "answers retain citations", %{dir: dir} do
    fake = fn :post, "/answer", _ ->
      {:ok, 200, %{},
       %{
         "answer" => "Yes [1]",
         "citations" => [%{"url" => "https://example.org", "title" => "Proof"}]
       }}
    end

    assert {:ok, r} = Search.answer("Question", transport: fake, dir: dir)
    assert r.text =~ "citations"
    assert r.text =~ "Proof"
  end

  test "rate limit retry is bounded and auth errors are sanitized", %{dir: dir} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fake = fn _, _, _ ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n == 0,
        do: {:ok, 429, %{"retry-after" => ["0"]}, %{}},
        else: {:ok, 200, %{}, %{"results" => []}}
    end

    assert {:ok, _} = Search.search("Q", transport: fake, dir: dir)
    assert Agent.get(counter, & &1) == 2

    assert {:error, %{kind: :http, status: 401}} =
             Search.answer("Q",
               transport: fn _, _, _ -> {:ok, 401, %{}, %{"secret" => "DO NOT RETURN"}} end
             )

    assert {:error, %{kind: :transport}} =
             Search.answer("Q", transport: fn _, _, _ -> raise "DO NOT RETURN" end)
  end

  test "giant JSON strings are completely accessible with bounded Unicode byte pages", %{dir: dir} do
    payload = String.duplicate("é日本🙂", 10000)

    fake = fn _, _, _ ->
      {:ok, 200, %{}, %{"answer" => payload, "citations" => [%{"url" => "https://example.org"}]}}
    end

    {:ok, r} = Search.answer("Q", dir: dir, transport: fake, max_bytes: 100)
    assert r.continuation =~ "read_bytes"

    chunks =
      Stream.unfold(0, fn
        nil ->
          nil

        offset ->
          assert {:ok, page} = Search.read_bytes(r.result, offset: offset, max_bytes: 1001)
          assert String.valid?(page.text)
          assert byte_size(page.text) <= 1001
          {page.text, page.next_offset}
      end)
      |> Enum.to_list()

    decoded = chunks |> Enum.join() |> Jason.decode!()
    assert decoded["answer"] == payload
    assert {:error, _} = Search.read_bytes(r.result, offset: r.bytes + 1)
  end

  test "research enforces explicit auto and ultra cost budgets", %{dir: dir} do
    caller = self()

    fake = fn _, _, body ->
      send(caller, {:sent, body})
      {:ok, 401, %{}, %{}}
    end

    for params <- [
          %{"effort" => "auto"},
          %{"effort" => "ultra", "budget" => %{"maxCostDollars" => 101}},
          %{"effort" => "wrong"}
        ] do
      assert {:error, _} =
               Search.research("Q",
                 owner: "absent-search-owner",
                 dir: dir,
                 transport: fake,
                 params: params
               )
    end

    refute_receive {:sent, _}

    assert {:ok, h} =
             Search.research("Q",
               owner: "absent-search-owner",
               dir: dir,
               transport: fake,
               params: %{"effort" => "auto", "budget" => %{"maxCostDollars" => 1}},
               delivery_timeout: 10
             )

    assert_receive {:sent, %{"budget" => %{"maxCostDollars" => 1}}}
    ref = Process.monitor(h.pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 1000
  end

  test "research storage failure still delivers a sanitized event", %{dir: dir} do
    owner = "search-storage-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    :yes = Nano.Names.register_name({:agent, owner}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, owner}) end)

    fake = fn _, _, _ ->
      File.rm_rf!(dir)
      {:ok, 200, %{}, %{"id" => "created-but-storage-failed", "status" => "completed"}}
    end

    {:ok, h} = Search.research("Q", owner: owner, dir: dir, transport: fake)

    assert_receive {:"$gen_cast",
                    {:notify, {:research, id, %{error: %{kind: :persistence_failed}}}}},
                   1000

    assert h.id == id
    assert {:error, _} = Search.status(h)
  end

  test "simultaneous resumes claim one worker",
       %{dir: dir} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}
    job_dir = Path.join(dir, "resume")
    File.mkdir_p!(job_dir)

    File.write!(
      Path.join(job_dir, "status.term"),
      :erlang.term_to_binary(%{
        status: :running,
        remote_id: "saved",
        owner: "old-owner",
        pid: dead
      })
    )

    handle = %{id: "resume", dir: job_dir, owner: "old-owner"}
    caller = self()

    fake = fn :get, "/agent/runs/saved", nil ->
      send(caller, :polled)
      Process.sleep(100)
      {:ok, 200, %{}, %{"id" => "saved", "status" => "completed"}}
    end

    tasks =
      for _ <- 1..8,
          do:
            Task.async(fn ->
              Search.resume(handle,
                owner: "absent-search-owner",
                dir: dir,
                transport: fake,
                delivery_timeout: 10
              )
            end)

    results = Enum.map(tasks, &Task.await(&1, 3000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert_receive :polled
    refute_receive :polled, 150
  end

  test "streamed HTTP body stops at 5 MB" do
    req = Req.new()
    resp = %Req.Response{status: 200, body: ""}
    assert {:cont, {^req, first}} = Search.collect_body({:data, "abc"}, {req, resp})
    assert first.body == {3, ["abc"]}

    assert catch_throw(
             Search.collect_body({:data, String.duplicate("x", 5_000_000)}, {req, first})
           ) == :response_too_large
  end

  test "overall HTTP timeout bounds slow providers",
       %{dir: dir} do
    fake = fn _, _, _ ->
      Process.sleep(1000)
      {:ok, 200, %{}, %{}}
    end

    start = System.monotonic_time(:millisecond)

    assert {:error, %{kind: :timeout}} =
             Search.answer("Q", dir: dir, timeout: 20, transport: fake)

    assert System.monotonic_time(:millisecond) - start < 500
  end

  test "interrupted research resumes saved remote ID", %{dir: dir} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}
    job_dir = Path.join(dir, "job")
    File.mkdir_p!(job_dir)

    File.write!(
      Path.join(job_dir, "status.term"),
      :erlang.term_to_binary(%{
        status: :running,
        remote_id: "saved",
        owner: "old-owner",
        pid: dead
      })
    )

    handle = %{id: "job", dir: job_dir, owner: "old-owner"}
    assert {:ok, %{status: :interrupted}} = Search.status(handle)

    fake = fn :get, "/agent/runs/saved", nil ->
      {:ok, 200, %{}, %{"id" => "saved", "status" => "completed", "output" => %{}}}
    end

    assert {:ok, h} =
             Search.resume(handle,
               owner: "absent-search-owner",
               dir: dir,
               transport: fake,
               delivery_timeout: 10
             )

    ref = Process.monitor(h.pid)
    assert_receive {:DOWN, ^ref, _, _, :normal}, 1000
    assert {:ok, %{status: "completed", owner: "absent-search-owner"}} = Search.status(h)
    assert {:error, %{kind: :not_resumable}} = Search.resume(h, owner: "absent-search-owner")
  end

  test "invalid arguments return values" do
    assert {:error, _} = Search.search("")
    assert {:error, _} = Search.search("Q", num_results: 51)
    assert {:error, _} = Search.contents([])
    assert {:error, _} = Search.research("Q", owner: "owner", params: %{effort: "auto"})

    assert {:error, _} =
             Search.research("Q",
               owner: "owner",
               params: %{
                 "effort" => "auto",
                 "budget" => %{"maxCostDollars" => 1, maxCostDollars: 100}
               }
             )

    assert {:error, _} = Search.research("Q", owner: self())
  end

  test "research creates once, polls, persists full grounding and emits stable name event", %{
    dir: dir
  } do
    owner = "search-test-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    :yes = Nano.Names.register_name({:agent, owner}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, owner}) end)
    caller = self()

    fake = fn
      :post, "/agent/runs", body ->
        send(caller, {:created, body})
        {:ok, 200, %{}, %{"id" => "run_1", "status" => "queued"}}

      :get, "/agent/runs/run_1", nil ->
        {:ok, 200, %{},
         %{
           "id" => "run_1",
           "status" => "completed",
           "output" => %{
             "text" => "Answer",
             "structured" => %{"fact" => "yes"},
             "grounding" => [%{"url" => "https://example.org"}]
           }
         }}
    end

    assert {:ok, handle} =
             Search.research("Q", owner: owner, dir: dir, transport: fake, poll_interval: 10)

    assert_receive {:created, %{"effort" => "minimal"}}, 1000

    assert_receive {:"$gen_cast", {:notify, {:research, id, %{status: "completed", result: r}}}},
                   1000

    assert id == handle.id
    assert r.text =~ "grounding"
    assert {:ok, %{status: "completed", remote_id: "run_1"}} = Search.status(handle)
  end

  test "research creation is not retried and absent owner doesn't lose persisted result", %{
    dir: dir
  } do
    caller = self()

    fake = fn _, _, _ ->
      send(caller, :create)
      {:ok, 429, %{}, %{}}
    end

    assert {:ok, h} =
             Search.research("Q",
               owner: "absent-search-owner",
               transport: fake,
               dir: dir,
               delivery_timeout: 10
             )

    assert_receive :create
    refute_receive :create, 150
    assert {:ok, %{status: :error, error: %{status: 429}}} = Search.status(h)
  end

  test "research deadline caps long polling sleeps and resumes after local timeout", %{dir: dir} do
    owner = "search-resume-timeout-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    :yes = Nano.Names.register_name({:agent, owner}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, owner}) end)

    fake = fn
      :post, "/agent/runs", _ -> {:ok, 200, %{}, %{"id" => "timed", "status" => "queued"}}
      :get, "/agent/runs/timed", _ -> {:ok, 200, %{}, %{"id" => "timed", "status" => "completed"}}
    end

    start = System.monotonic_time(:millisecond)

    {:ok, h} =
      Search.research("Q",
        owner: owner,
        dir: dir,
        transport: fake,
        research_timeout: 20,
        poll_interval: 60000
      )

    assert_receive {:"$gen_cast",
                    {:notify,
                     {:research, _, %{status: :error, error: %{kind: :research_timeout}}}}},
                   500

    assert System.monotonic_time(:millisecond) - start < 500
    assert {:ok, resumed} = Search.resume(h, owner: owner, transport: fake)
    assert resumed.owner == owner
    assert_receive {:"$gen_cast", {:notify, {:research, _, %{status: "completed"}}}}, 1000
  end

  test "resumed initial GET shares research deadline", %{dir: dir} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}
    job_dir = Path.join(dir, "initial")
    File.mkdir_p!(job_dir)

    File.write!(
      Path.join(job_dir, "status.term"),
      :erlang.term_to_binary(%{
        status: :running,
        remote_id: "initial",
        owner: "old-owner",
        pid: dead
      })
    )

    handle = %{id: "initial", dir: job_dir, owner: "old-owner"}

    fake = fn _, _, _ ->
      Process.sleep(1000)
      {:ok, 200, %{}, %{"id" => "initial", "status" => "completed"}}
    end

    start = System.monotonic_time(:millisecond)

    {:ok, h} =
      Search.resume(handle,
        owner: "absent-search-owner",
        transport: fake,
        research_timeout: 20,
        delivery_timeout: 10
      )

    ref = Process.monitor(h.pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 500
    assert System.monotonic_time(:millisecond) - start < 500
    assert {:ok, %{status: :error, error: %{kind: :research_timeout}}} = Search.status(h)
  end

  test "research deadline caps slow polling HTTP and cancellation output is bounded",
       %{dir: dir} do
    fake = fn
      :post, "/agent/runs", _ ->
        {:ok, 200, %{}, %{"id" => "slow", "status" => "queued"}}

      :get, "/agent/runs/slow", _ ->
        Process.sleep(1000)
        {:ok, 200, %{}, %{"id" => "slow", "status" => "completed"}}

      :post, "/agent/runs/slow/cancel", _ ->
        {:ok, 200, %{}, %{"status" => "cancelled", "output" => String.duplicate("x", 100_000)}}
    end

    start = System.monotonic_time(:millisecond)

    {:ok, h} =
      Search.research("Q",
        owner: "absent-search-owner",
        dir: dir,
        transport: fake,
        research_timeout: 50,
        poll_interval: 10,
        delivery_timeout: 10
      )

    ref = Process.monitor(h.pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 500
    assert System.monotonic_time(:millisecond) - start < 500
    assert {:ok, %{error: %{kind: :research_timeout}}} = Search.status(h)
    assert {:ok, r} = Search.cancel(h, transport: fake, max_bytes: 100)
    assert byte_size(r.text) <= 100
    assert r.cut
    assert {:ok, %{status: "cancelled"}} = Search.status(h)
  end

  test "research timeout keeps remote ID for cancellation",
       %{dir: dir} do
    fake = fn
      :post, "/agent/runs", _ -> {:ok, 200, %{}, %{"id" => "run_2", "status" => "queued"}}
      :get, "/agent/runs/run_2", _ -> {:ok, 200, %{}, %{"id" => "run_2", "status" => "running"}}
      :post, "/agent/runs/run_2/cancel", _ -> {:ok, 200, %{}, %{"status" => "cancelled"}}
    end

    {:ok, h} =
      Search.research("Q",
        owner: "absent-search-owner",
        transport: fake,
        dir: dir,
        research_timeout: 10,
        poll_interval: 10,
        delivery_timeout: 10
      )

    ref = Process.monitor(h.pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 1000

    assert {:ok, %{status: :error, error: %{kind: :research_timeout}, remote_id: "run_2"}} =
             Search.status(h)

    assert {:ok, r} = Search.cancel(h, transport: fake)
    assert r.text =~ "cancelled"
    assert {:ok, %{status: "cancelled"}} = Search.status(h)
  end
end
