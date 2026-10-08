defmodule SeedDecisionTest do
  use ExUnit.Case, async: true

  @reply %{bot: %{name: "Mira"}, message: %{text: "Mira, can you help?"}, exchange_count: 0}
  @candidates [%{id: "a", text: "Tea"}, %{id: "b", text: "Coffee"}, %{id: "c", text: "Cake"}]

  defp answer(p), do: %{"type" => "noul", "noul" => p}
  defp response(answers), do: {:ok, %{status: 200, body: %{"answers" => answers}}}
  defp fake(answers), do: fn _ -> response(answers) end
  defp reply_opts(p), do: [api_key: "test-only-key", http: fake(%{"reply" => answer(p)})]

  defp memory_state(candidates \\ @candidates),
    do: %{query: "What should I drink?", candidates: candidates}

  test "uses the documented endpoint and Noul probability, not confidence" do
    http = fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://api.typesafe.ai/v1/systemone"
      assert opts[:headers] == [{"authorization", "Bearer test-only-key"}]
      assert opts[:retry] == false
      assert opts[:redirect] == false
      assert opts[:receive_timeout] == 5_000
      assert opts[:connect_options] == [timeout: 5_000]
      assert opts[:json].model == "jev-latest"
      assert opts[:json].state == @reply
      assert opts[:json].questions["reply"].type == "noul"
      response(%{"reply" => Map.put(answer(0.81), "confidence", 0.1)})
    end

    assert {:ok, %{reply: true, probability: 0.81}} =
             SeedDecision.decide(:reply, @reply, api_key: "test-only-key", http: http)
  end

  test "reply threshold includes its boundary and returns a float" do
    assert {:ok, %{reply: false, probability: 0.74}} =
             SeedDecision.decide(:reply, @reply, reply_opts(0.74))

    assert {:ok, %{reply: true, probability: 0.75}} =
             SeedDecision.decide(:reply, @reply, reply_opts(0.75))

    assert {:ok, %{reply: true, probability: 1.0}} =
             SeedDecision.decide(:reply, @reply, reply_opts(1))

    assert {:ok, %{reply: false, probability: 0.81}} =
             SeedDecision.decide(:reply, @reply, reply_opts(0.81) ++ [threshold: 0.9])
  end

  test "per-call model, endpoint, timeout and string keys" do
    http = fn opts ->
      assert opts[:url] == "http://127.0.0.1:10000/v1/systemone"
      assert opts[:json].model == "jev-pinned"
      assert opts[:receive_timeout] == 100
      assert opts[:connect_options] == [timeout: 100]
      response(%{"reply" => answer(0)})
    end

    state = %{"bot" => "Mira", "message" => "Hello", "exchange_count" => 3}

    assert {:ok, %{reply: false, probability: +0.0}} =
             SeedDecision.decide(:reply, state,
               api_key: "test-only-key",
               http: http,
               endpoint: "http://127.0.0.1:10000/v1/systemone",
               model: "jev-pinned",
               timeout: 100
             )
  end

  test "memory questions batched, ranked, capped, stable ties and no invented ids" do
    http = fn opts ->
      assert opts[:json].state == memory_state()
      assert Map.keys(opts[:json].questions) |> Enum.sort() == ~w(memory_0 memory_1 memory_2)
      assert opts[:json].questions["memory_0"].instructions =~ "state.candidates[0]"
      assert opts[:json].questions["memory_2"].instructions =~ "state.candidates[2]"

      response(%{
        "memory_0" => answer(0.7),
        "memory_1" => answer(0.91),
        "memory_2" => answer(0.91),
        "invented-id" => answer(1)
      })
    end

    opts = [api_key: "test-only-key", http: http]
    assert {:ok, %{ids: ["b", "c", "a"]}} = SeedDecision.decide(:memory, memory_state(), opts)

    assert {:ok, %{ids: ["b", "c"]}} =
             SeedDecision.decide(:memory, memory_state(), opts ++ [max_memories: 2])

    assert {:ok, %{ids: []}} =
             SeedDecision.decide(:memory, memory_state(), opts ++ [threshold: 0.99])
  end

  test "memory candidates with string keys and empty inputs" do
    state = %{"query" => "drink", "candidates" => [%{"id" => "drink", "text" => "tea"}]}

    assert {:ok, %{ids: ["drink"]}} =
             SeedDecision.decide(:memory, state,
               api_key: "test-only-key",
               http: fake(%{"memory_0" => answer(1)})
             )

    assert {:ok, %{ids: []}} =
             SeedDecision.decide(:memory, memory_state([]),
               api_key: nil,
               http: fn _ -> flunk("empty candidates should not need the API") end
             )
  end

  test "missing or blank key is explicit unavailable, never a fallback" do
    for key <- [nil, "", "  "] do
      assert {:error, {:unavailable, :missing_api_key}} =
               SeedDecision.decide(:reply, @reply,
                 api_key: key,
                 http: fn _ -> flunk("must not call HTTP") end
               )
    end
  end

  test "transport reasons and exceptions cannot leak secrets" do
    for http <- [
          fn _ -> {:error, "secret"} end,
          fn _ -> raise "secret" end,
          fn _ -> throw("secret") end,
          fn _ -> exit("secret") end
        ] do
      assert {:error, {:unavailable, :transport_error}} =
               SeedDecision.decide(:reply, @reply, api_key: "test-only-key", http: http)
    end
  end

  test "HTTP failures are explicit and do not expose response bodies" do
    for status <- [301, 401, 422, 429, 500, 529] do
      assert {:error, {:http_status, ^status}} =
               SeedDecision.decide(:reply, @reply,
                 api_key: "test-only-key",
                 http: fn _ -> {:ok, %{status: status, body: "secret"}} end
               )
    end
  end

  test "reject malformed or out of range probabilities rather than becoming false" do
    for value <- [nil, "0.9", true, -0.1, 1.1, %{}] do
      assert {:error, :invalid_response} = SeedDecision.decide(:reply, @reply, reply_opts(value))
    end

    for body <- [
          nil,
          %{},
          %{"answers" => []},
          %{"answers" => %{}},
          %{"answers" => %{"reply" => %{"type" => "choice", "noul" => 0.9}}},
          %{"answers" => %{"reply" => %{"type" => "noul", "probability" => 0.9}}},
          "not JSON"
        ] do
      assert {:error, :invalid_response} =
               SeedDecision.decide(:reply, @reply,
                 api_key: "test-only-key",
                 http: fn _ -> {:ok, %{status: 200, body: body}} end
               )
    end
  end

  test "decode JSON strings and reject malformed HTTP shapes" do
    json = Jason.encode!(%{"answers" => %{"reply" => answer(0.88)}})

    assert {:ok, %{reply: true, probability: 0.88}} =
             SeedDecision.decide(:reply, @reply,
               api_key: "test-only-key",
               http: fn _ -> {:ok, %{status: 200, body: json}} end
             )

    assert {:error, :invalid_response} =
             SeedDecision.decide(:reply, @reply,
               api_key: "test-only-key",
               http: fn _ -> :unexpected end
             )
  end

  test "memory requires every answer even if enough selected ids exist" do
    assert {:error, :invalid_response} =
             SeedDecision.decide(:memory, memory_state(),
               api_key: "test-only-key",
               max_memories: 1,
               http: fake(%{"memory_0" => answer(1)})
             )
  end

  test "invalid state and bounds fail before HTTP" do
    opts = [api_key: "test-only-key", http: fn _ -> flunk("must not call HTTP") end]

    for state <- [
          nil,
          %{},
          Map.delete(@reply, :bot),
          Map.put(@reply, :exchange_count, -1),
          Map.put(@reply, :exchange_count, 1.2),
          Map.put(@reply, :message, self())
        ] do
      assert {:error, :invalid_state} = SeedDecision.decide(:reply, state, opts)
    end

    for candidates <- [
          [%{text: "no id"}],
          [%{id: 123}],
          [%{id: " "}],
          ["id"],
          [%{id: "same"}, %{id: "same"}]
        ] do
      assert {:error, :invalid_state} =
               SeedDecision.decide(:memory, memory_state(candidates), opts)
    end

    assert {:error, :too_many_candidates} =
             SeedDecision.decide(:memory, memory_state(for i <- 1..65, do: %{id: "#{i}"}), opts)

    assert {:error, :state_too_large} =
             SeedDecision.decide(
               :reply,
               Map.put(@reply, :message, String.duplicate("x", 131_073)),
               opts
             )
  end

  test "invalid options are local errors" do
    for opts <- [
          nil,
          %{},
          [:oops],
          [unknown: true],
          [threshold: -0.1],
          [threshold: 1.1],
          [timeout: 0],
          [timeout: 5_001],
          [max_memories: -1],
          [max_memories: 65],
          [http: nil],
          [model: ""],
          [endpoint: "not a url"],
          [endpoint: "https://user:secret@host"]
        ] do
      assert {:error, :invalid_options} = SeedDecision.decide(:reply, @reply, opts)
    end

    assert {:error, :invalid_options} = SeedDecision.decide(:unknown, @reply, [])
  end

  defmodule Endpoint do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, listener) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        listener,
        {:decision_http, conn.method, conn.request_path, conn.req_headers, Jason.decode!(body)}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"answers" => %{"reply" => %{"type" => "noul", "noul" => 0.92}}})
      )
    end
  end

  test "default Req adapter sends real authenticated JSON to an isolated port-zero server" do
    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, self()}, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    assert {:ok, %{reply: true, probability: 0.92}} =
             SeedDecision.decide(:reply, @reply,
               api_key: "test-only-key",
               endpoint: "http://127.0.0.1:#{port}/v1/systemone"
             )

    assert_receive {:decision_http, "POST", "/v1/systemone", headers, payload}
    assert {"authorization", "Bearer test-only-key"} in headers
    assert {"content-type", "application/json"} in headers
    assert payload["model"] == "jev-latest"
    assert payload["questions"]["reply"]["type"] == "noul"
    assert payload["state"]["exchange_count"] == 0
  end
end
