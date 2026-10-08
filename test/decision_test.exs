defmodule DecisionTest do
  use ExUnit.Case, async: true

  defp questions do
    [
      Decision.noul("urgent", "Is it urgent?"),
      Decision.choice("team", "Which team?", %{"billing" => "Payments", "tech" => nil}),
      Decision.score("severity", "How severe?", ["Calm", "Frustrated", "Angry"])
    ]
  end

  defp answers do
    %{
      "urgent" => %{"type" => "noul", "noul" => 0.95},
      "team" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.88, "tech" => 0.12},
        "confidence" => 0.81
      },
      "severity" => %{
        "type" => "score",
        "score" => 1.05,
        "probabilities" => %{"0" => 0.0, "1" => 0.95, "2" => 0.05},
        "confidence" => 0.92,
        "legend" => %{"0" => "Calm", "1" => "Frustrated", "2" => "Angry"}
      }
    }
  end

  defp run_answers(answers, qs \\ questions()) do
    Decision.ask("Help, my payouts failed!", qs,
      api_key: "fake-key",
      transport: fn _ -> {:ok, %{status: 200, body: %{"answers" => answers}}} end
    )
  end

  test "documented HTTP shape, canonical JSON state, and all three typed answers" do
    parent = self()

    fake = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 200, body: Jason.encode!(%{"answers" => answers(), "model" => "jev-test"})}}
    end

    assert {:ok, results} =
             Decision.ask(%{text: "Help!"}, questions(), api_key: "fake-key", transport: fake)

    assert_receive {:request, request}
    assert request.url == "https://api.typesafe.ai/v1/systemone"
    assert request.headers == [{"authorization", "Bearer fake-key"}]
    assert request.timeout == 15_000
    assert request.connect_timeout == 5_000
    assert request.json["state"] == %{"text" => "Help!"}
    assert request.json["model"] == "jev-latest"

    assert request.json["questions"]["urgent"] == %{
             "type" => "noul",
             "instructions" => "Is it urgent?"
           }

    assert request.json["questions"]["team"]["criteria"] == %{
             "billing" => "Payments",
             "tech" => nil
           }

    assert request.json["questions"]["severity"]["criteria"] == ["Calm", "Frustrated", "Angry"]
    assert %Decision.Answer{type: :noul, value: 0.95, confidence: nil} = results["urgent"]
    assert %Decision.Answer{type: :choice, value: "billing", confidence: 0.81} = results["team"]
    assert results["team"].probabilities == %{"billing" => 0.88, "tech" => 0.12}
    assert %Decision.Answer{type: :score, value: 1.05, confidence: 0.92} = results["severity"]
    assert results["severity"].legend["2"] == "Angry"
  end

  test "structured instructions, criteria and state; custom model and timeout" do
    q = Decision.choice("x", %{question: "Which?"}, %{"a" => %{meaning: ["alpha"]}})
    parent = self()

    assert {:ok, _} =
             Decision.ask([%{item: 1}], [q],
               api_key: "fake-key",
               model: "jev-pinned",
               timeout: 1000,
               transport: fn request ->
                 send(parent, {:request, request})

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "answers" => %{
                        "x" => %{
                          "type" => "choice",
                          "choice" => "a",
                          "probabilities" => %{"a" => 1},
                          "confidence" => 1
                        }
                      }
                    }
                  }}
               end
             )

    assert_receive {:request, request}
    assert request.connect_timeout == 1000
    assert request.json["model"] == "jev-pinned"
    assert request.json["questions"]["x"]["instructions"] == %{"question" => "Which?"}
  end

  test "invalid questions fail before transport, including duplicate IDs and API size limits" do
    parent = self()

    fake = fn _ ->
      send(parent, :called)
      {:error, :should_not_call}
    end

    invalids = [
      [],
      List.duplicate(Decision.noul("x", "yes?"), 129),
      [Decision.noul("x", "yes?"), Decision.noul("x", "no?")],
      [Decision.noul(:atom, "yes?")],
      [Decision.noul("", "yes?")],
      [Decision.noul("x", "")],
      [%{type: "noul"}],
      [Decision.choice("x", "which?", %{})],
      [Decision.choice("x", "which?", %{atom: "no"})],
      [Decision.choice("x", "which?", %{"a" => 42})],
      [Decision.choice("x", "which?", Map.new(1..256, &{to_string(&1), nil}))],
      [Decision.score("x", "how?", ["one"])],
      [Decision.score("x", "how?", List.duplicate("level", 11))],
      [Decision.score("x", "how?", [nil, "high"])]
    ]

    for qs <- invalids,
        do: assert({:error, _} = Decision.ask("state", qs, api_key: "fake-key", transport: fake))

    refute_receive :called
  end

  test "invalid inputs, non-JSON terms, duplicate JSON keys, and request byte budget" do
    opts = [api_key: "fake-key", transport: fn _ -> flunk("must not call transport") end]

    for state <- [nil, true, 3, "", <<255>>, self()] do
      assert {:error, {:invalid_input, :state}} = Decision.ask(state, questions(), opts)
    end

    for state <- [%{bad: self()}, %{"key" => 1, key: 2}] do
      assert {:error, {:invalid_input, :json}} = Decision.ask(state, questions(), opts)
    end

    assert {:error, {:invalid_input, :request_too_large}} =
             Decision.ask(String.duplicate("a", 262_145), questions(), opts)

    for {key, value} <- [
          timeout: 0,
          timeout: :infinity,
          timeout: 60_001,
          connect_timeout: -1,
          transport: :bad,
          model: ""
        ] do
      assert {:error, {:invalid_input, ^key}} =
               Decision.ask("state", questions(), Keyword.put(opts, key, value))
    end

    assert {:error, {:invalid_input, :options}} = Decision.ask("state", questions(), :bad)

    assert {:error, {:invalid_input, :options}} =
             Decision.ask("state", questions(), unknown: true)
  end

  test "missing credentials fail explicitly without network" do
    for key <- [nil, "", "   ", 123] do
      assert {:error, :missing_api_key} =
               Decision.ask("state", questions(),
                 api_key: key,
                 transport: fn _ -> flunk("must not call transport") end
               )
    end
  end

  test "response must cover exact requested IDs and correct types" do
    for a <- [%{}, Map.delete(answers(), "team"), Map.put(answers(), "extra", %{})] do
      assert {:error, {:invalid_response, :answer_ids}} = run_answers(a)
    end

    for value <- [nil, 0.5, %{"type" => "choice", "noul" => 0.5}, %{"type" => "noul"}] do
      assert {:error, {:invalid_response, {"urgent", :answer_shape}}} =
               run_answers(Map.put(answers(), "urgent", value))
    end
  end

  test "noul validates numbers in closed unit interval without coercion" do
    for value <- [-0.1, 1.1, "0.5", true, nil] do
      assert {:error, {:invalid_response, {"urgent", :noul}}} =
               run_answers(put_in(answers(), ["urgent", "noul"], value))
    end

    for value <- [0, 1, 0.0, 1.0] do
      assert {:ok, _} = run_answers(put_in(answers(), ["urgent", "noul"], value))
    end
  end

  test "choice distributions validate coverage, probabilities, sum, confidence and winning option" do
    for {field, value, reason} <- [
          {"probabilities", [], :probabilities},
          {"probabilities", %{"billing" => 1}, :probability_keys},
          {"probabilities", %{"billing" => 1, "tech" => 0, "extra" => 0}, :probability_keys},
          {"probabilities", %{"billing" => -0.1, "tech" => 1.1}, :probabilities},
          {"probabilities", %{"billing" => "0.8", "tech" => 0.2}, :probabilities},
          {"probabilities", %{"billing" => 0.4, "tech" => 0.4}, :probability_sum},
          {"confidence", nil, :confidence},
          {"confidence", 1.1, :confidence},
          {"choice", "other", :choice},
          {"choice", "tech", :choice_probability}
        ] do
      assert {:error, {:invalid_response, {"team", ^reason}}} =
               run_answers(put_in(answers(), ["team", field], value))
    end

    assert {:ok, _} =
             run_answers(
               put_in(answers(), ["team", "probabilities"], %{"billing" => 0.5, "tech" => 0.5})
             )
  end

  test "scores validate weighted mean, bounds, level keys and legend" do
    for {field, value, reason} <- [
          {"score", "1.05", :score},
          {"score", -1, :score},
          {"score", 2.1, :score},
          {"score", 0.0, :score_probability},
          {"legend", %{}, :legend},
          {"legend", nil, :legend},
          {"legend", %{"0" => 4, "1" => "middle", "2" => "high"}, :legend},
          {"probabilities", %{"1" => 0.0, "2" => 0.95, "3" => 0.05}, :probability_keys}
        ] do
      assert {:error, {:invalid_response, {"severity", ^reason}}} =
               run_answers(put_in(answers(), ["severity", field], value))
    end
  end

  test "HTTP errors do not leak response body or credentials and are never retried" do
    for status <- [301, 401, 422, 429, 500, 529] do
      parent = self()

      assert {:error, {:http_status, ^status}} =
               Decision.ask("state", questions(),
                 api_key: "fake-key",
                 transport: fn _ ->
                   send(parent, :called)
                   {:ok, %{status: status, body: "sensitive"}}
                 end
               )

      assert_receive :called
      refute_receive :called, 1
    end
  end

  test "malformed JSON and oversized responses are errors" do
    for {body, reason} <- [
          {"not-json", :json},
          {"[]", :json},
          {nil, :json},
          {%{}, :answers},
          {String.duplicate("a", 1_048_577), :response_too_large},
          {%{"large" => String.duplicate("a", 1_048_577)}, :response_too_large}
        ] do
      assert {:error, {:invalid_response, ^reason}} =
               Decision.ask("state", questions(),
                 api_key: "fake-key",
                 transport: fn _ -> {:ok, %{status: 200, body: body}} end
               )
    end
  end

  test "transport exceptions, throws, exits and opaque errors are sanitized" do
    for {fake, expected} <- [
          {fn _ -> raise "secret credential" end, :exception},
          {fn _ -> throw("secret credential") end, :exception},
          {fn _ -> exit("secret credential") end, :exception},
          {fn _ -> {:error, %{secret: "credential"}} end, :failed},
          {fn _ -> {:error, :econnrefused} end, :econnrefused},
          {fn _ -> {:error, %Req.TransportError{reason: :timeout}} end, :timeout},
          {fn _ -> :bad end, :invalid_result},
          {fn _ -> Process.exit(self(), :kill) end, :crashed}
        ] do
      assert {:error, {:transport, ^expected}} =
               Decision.ask("state", questions(), api_key: "fake-key", transport: fake)
    end
  end

  test "killing the caller cancels its blocked transport rather than orphaning it" do
    parent = self()

    caller =
      spawn(fn ->
        Decision.ask("state", questions(),
          api_key: "fake-key",
          timeout: 60_000,
          transport: fn _ ->
            send(parent, {:worker, self()})
            Process.sleep(:infinity)
          end
        )
      end)

    assert_receive {:worker, worker}
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1000
    refute Process.alive?(worker)
  end

  test "whole transport deadline kills worker and leaves no late result or monitor messages" do
    parent = self()
    start = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Decision.ask("state", questions(),
               api_key: "fake-key",
               timeout: 20,
               transport: fn _ ->
                 send(parent, {:worker, self()})
                 Process.sleep(:infinity)
               end
             )

    assert System.monotonic_time(:millisecond) - start < 1000
    assert_receive {:worker, pid}
    refute Process.alive?(pid)
    refute_receive {:DOWN, _, _, _, _}, 10
    refute_receive {_, _}, 10
  end
end
