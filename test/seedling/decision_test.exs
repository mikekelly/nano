defmodule Seedling.DecisionTest do
  use ExUnit.Case, async: true
  alias Seedling.Decision

  test "missing credentials never invokes transport" do
    assert {:error, :missing_credentials} =
             Decision.probability("state", "question",
               api_key: nil,
               transport: fn _ -> flunk("unexpected request") end
             )
  end

  test "multiple typed questions preserve probabilities, confidence and measured usage" do
    qs = %{
      reply: %{type: "noul", instructions: "Needs reply"},
      topic: %{type: "choice", instructions: "Topic", criteria: %{build: "Code", social: "Chat"}},
      relevance: %{type: "score", instructions: "Memory relevance", criteria: ["None", "High"]}
    }

    answers = %{
      "reply" => %{"type" => "noul", "noul" => 0.8},
      "topic" => %{
        "type" => "choice",
        "choice" => "build",
        "confidence" => 0.7,
        "probabilities" => %{"build" => 0.9, "social" => 0.1}
      },
      "relevance" => %{
        "type" => "score",
        "score" => 1,
        "confidence" => 0.75,
        "probabilities" => %{"0" => 0.1, "1" => 0.9}
      }
    }

    transport = fn request ->
      assert request[:retry] == false
      assert request[:receive_timeout] == 3_000
      assert request[:json].questions["reply"]["type"] == "noul"

      {:ok,
       %{
         status: 200,
         body: %{
           "answers" => answers,
           "model" => "jev-fake",
           "usage" => %{"input_tokens" => 33, "output_tokens" => 10}
         }
       }}
    end

    assert {:ok, %{answers: ^answers, model: "jev-fake", usage: %{"input_tokens" => 33}}} =
             Decision.evaluate("Compact state", qs, api_key: "fake", transport: transport)
  end

  test "probability convenience returns one Noul judgement" do
    transport = fn _ ->
      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "fake",
           "answers" => %{"judgement" => %{"type" => "noul", "noul" => 0.25}}
         }
       }}
    end

    assert {:ok, %{probability: 0.25, model: "fake"}} =
             Decision.probability("s", "q", api_key: "fake", transport: transport)
  end

  test "invalid inputs and malformed native answers are honest errors" do
    opts = [api_key: "fake", transport: fn _ -> flunk("bad input must not request") end]

    assert {:error, :state_too_large} =
             Decision.evaluate(
               String.duplicate("x", 16_001),
               %{q: %{type: "noul", instructions: "q"}},
               opts
             )

    assert {:error, :invalid_questions} = Decision.evaluate("s", %{}, opts)
    assert {:error, :invalid_questions} = Decision.evaluate("s", %{q: "not a question"}, opts)

    assert {:error, :invalid_questions} =
             Decision.evaluate("s", %{q: %{type: "unknown", instructions: "q"}}, opts)

    for answers <- [
          %{},
          %{"judgement" => %{"type" => "score", "noul" => 0.2}},
          %{"judgement" => %{"type" => "noul", "noul" => -0.1}}
        ] do
      assert {:error, :invalid_response} =
               Decision.probability("s", "q",
                 api_key: "fake",
                 transport: fn _ ->
                   {:ok, %{status: 200, body: %{"model" => "fake", "answers" => answers}}}
                 end
               )
    end
  end
end
