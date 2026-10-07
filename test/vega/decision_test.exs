defmodule Vega.DecisionTest do
  use ExUnit.Case, async: true
  alias Vega.Decision
  @questions %{"urgent" => %{"type" => "noul", "instructions" => "Is this urgent?"}}
  test "no credentials is explicit" do
    assert {:error, :missing_api_key} = Decision.evaluate("x", @questions, api_key: nil)
  end

  test "invalid requests don't reach service" do
    assert {:error, :invalid_request} = Decision.evaluate("x", %{}, api_key: "test")

    assert {:error, :invalid_request} =
             Decision.evaluate("x", %{"x" => %{"type" => "fiction", "instructions" => "x"}},
               api_key: "test"
             )
  end

  test "scripted HTTP fixture validates answers, sends documented payload" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"model" => "jev-latest", "questions" => @questions, "state" => "Help now"} =
               Jason.decode!(body)

      Req.Test.json(conn, %{
        model: "fixture-not-real",
        answers: %{urgent: %{type: "noul", noul: 0.9}},
        usage: %{input_tokens: 10}
      })
    end)

    assert {:ok, %{"answers" => %{"urgent" => %{"noul" => 0.9}}}} =
             Decision.evaluate("Help now", @questions,
               api_key: "test",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "malformed or mismatched answers rejected" do
    for answer <- [
          %{},
          %{urgent: %{type: "noul", noul: 4}},
          %{urgent: %{type: "choice", noul: 1}}
        ] do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{answers: answer}) end)

      assert {:error, :invalid_response} =
               Decision.evaluate("x", @questions,
                 api_key: "test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  test "HTTP errors expose status, not secrets or response bodies" do
    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 401, "secret detail") end)

    assert {:error, {:http_status, 401}} =
             Decision.evaluate("x", @questions,
               api_key: "test",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "choice and score distributions validated" do
    q = %{
      "team" => %{
        "type" => "choice",
        "instructions" => "Team?",
        "criteria" => %{"a" => "A", "b" => "B"}
      },
      "severity" => %{
        "type" => "score",
        "instructions" => "Severity?",
        "criteria" => ["Low", "High"]
      }
    }

    Req.Test.stub(__MODULE__, fn c ->
      Req.Test.json(c, %{
        answers: %{
          team: %{type: "choice", choice: "a", confidence: 0.8, probabilities: %{a: 0.9, b: 0.1}},
          severity: %{
            type: "score",
            score: 0.5,
            confidence: 0.9,
            probabilities: %{"0" => 0.5, "1" => 0.5}
          }
        }
      })
    end)

    assert {:ok, _} =
             Decision.evaluate("x", q,
               api_key: "test",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end
end
