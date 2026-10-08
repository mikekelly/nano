defmodule Seedling.FrontOfMind.DriftTest do
  use ExUnit.Case, async: true
  alias Seedling.FrontOfMind.Drift

  test "missing credentials never invokes transport" do
    assert {:error, :missing_credentials} =
             Drift.judge("note", "recent",
               api_key: nil,
               transport: fn _ -> flunk("must not call") end
             )
  end

  test "typed request and response, bounded state, no retries" do
    transport = fn request ->
      assert request[:headers] == [{"authorization", "Bearer fake"}]
      assert request[:retry] == false
      assert request[:json].questions["judgement"]["type"] == "noul"
      assert String.length(request[:json].state) < 3_100

      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "jev-fake",
           "answers" => %{"judgement" => %{"type" => "noul", "noul" => 0.75}},
           "usage" => %{"input_tokens" => 10}
         }
       }}
    end

    assert {:ok, %{probability: 0.75, model: "jev-fake", usage: %{"input_tokens" => 10}}} =
             Drift.judge(String.duplicate("n", 2_000), String.duplicate("a", 4_000),
               api_key: "fake",
               transport: transport
             )
  end

  test "bad responses and http errors do not masquerade as drift" do
    for body <- [%{}, %{"answers" => %{"judgement" => %{"type" => "noul", "noul" => 1.1}}}] do
      assert {:error, :invalid_response} =
               Drift.judge("n", "a",
                 api_key: "fake",
                 transport: fn _ -> {:ok, %{status: 200, body: body}} end
               )
    end

    assert {:error, {:http_status, 401}} =
             Drift.judge("n", "a", api_key: "fake", transport: fn _ -> {:ok, %{status: 401}} end)

    assert {:error, :transport_failed} =
             Drift.judge("n", "a", api_key: "fake", transport: fn _ -> {:error, :timeout} end)
  end
end
