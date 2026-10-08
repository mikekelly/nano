defmodule Seedling.DecisionTest do
  use ExUnit.Case, async: true
  alias Seedling.Decision, as: D
  test "all typed primitives, sanitized failures and exact question matching" do
    questions = %{"urgent" => D.noul("Urgent?"), "route" => D.choice("Team?", %{"a" => "A", "b" => "B"}), "severity" => D.score("Severe?", ["low", "high"])}
    answers = %{"urgent" => %{"type" => "noul", "noul" => 0.8}, "route" => %{"type" => "choice", "choice" => "a", "confidence" => 0.8, "probabilities" => %{"a" => 0.9, "b" => 0.1}}, "severity" => %{"type" => "score", "score" => 0.7, "confidence" => 0.7, "probabilities" => %{"0" => 0.3, "1" => 0.7}}}
    transport = fn opts ->
      assert opts[:auth] == {:bearer, "test-only"}
      assert opts[:json].questions == questions
      {:ok, %{status: 200, body: %{"answers" => answers, "model" => "fake"}}}
    end
    assert {:ok, %{answers: ^answers}} = D.evaluate("state", questions, key: "test-only", transport: transport)
    assert {:error, :missing_typesafe_api_key} = D.evaluate("state", questions, key: nil)
    assert {:error, :invalid_response} = D.evaluate("state", questions, key: "test-only", transport: fn _ -> {:ok, %{status: 200, body: %{"answers" => Map.delete(answers, "route")}}} end)
    assert {:error, {:http_status, 401}} = D.evaluate("state", questions, key: "test-only", transport: fn _ -> {:ok, %{status: 401, body: "secret-key"}} end)
  end
end
