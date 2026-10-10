defmodule Nano.DecisionTest do
  use ExUnit.Case, async: true
  alias Nano.Decision, as: D

  defp run(q, answers, opts \\ []) do
    D.evaluate(
      "state",
      q,
      Keyword.merge(
        [
          api_key: "fake-secret",
          transport: fn _ ->
            {:ok, %{status: 200, body: %{"model" => "jev-test", "answers" => answers}}}
          end
        ],
        opts
      )
    )
  end

  test "typed answers retain probabilities and confidence" do
    q = %{
      "n" => D.noul("True?"),
      "c" => D.choice("Which?", %{"a" => nil, "b" => "Other"}),
      "s" => D.score("Rate", ["low", "high"])
    }

    a = %{
      "n" => %{"type" => "noul", "noul" => 0.9},
      "c" => %{
        "type" => "choice",
        "choice" => "a",
        "probabilities" => %{"a" => 0.8, "b" => 0.2},
        "confidence" => 0.6
      },
      "s" => %{
        "type" => "score",
        "score" => 0.7,
        "probabilities" => %{"0" => 0.3, "1" => 0.7},
        "confidence" => 0.4,
        "legend" => %{"0" => "low", "1" => "high"}
      }
    }

    assert {:ok, r} = run(q, a)
    assert r.answers["n"] == %{type: :noul, noul: 0.9}
    assert r.answers["c"].probabilities == %{"a" => 0.8, "b" => 0.2}
    assert r.answers["s"].score == 0.7
    assert r.answers["s"].confidence == 0.4
  end

  test "request endpoint, credentials and model" do
    parent = self()

    assert {:error, {:http_status, 429}} =
             D.evaluate(%{hello: "world"}, %{"n" => D.noul("True?")},
               api_key: "fake-secret",
               timeout: 100,
               transport: fn r ->
                 send(parent, {:request, r})
                 {:ok, %{status: 429, body: "fake-secret"}}
               end
             )

    assert_receive {:request, r}
    assert r.url == "https://api.typesafe.ai/v1/systemone"
    assert r.headers == [{"authorization", "Bearer fake-secret"}]
    assert r.body["model"] == "jev-latest"
    assert r.timeout == 100
  end

  test "errors and exceptions never leak credentials" do
    for f <- [
          fn _ -> {:error, "fake-secret"} end,
          fn _ -> raise "fake-secret" end,
          fn _ -> throw("fake-secret") end
        ] do
      assert {:error, :transport_error} ==
               D.evaluate("s", %{"n" => D.noul("?")}, api_key: "fake-secret", transport: f)
    end
  end

  test "timeout kills worker and leaves no result messages" do
    parent = self()

    assert {:error, :timeout} ==
             D.evaluate("s", %{"n" => D.noul("?")},
               api_key: "fake",
               timeout: 20,
               transport: fn _ ->
                 send(parent, {:worker, self()})
                 Process.sleep(:infinity)
               end
             )

    assert_receive {:worker, pid}
    refute Process.alive?(pid)
    refute_receive {_, _}, 20
  end

  test "rejects invalid input before transport" do
    f = fn _ -> flunk("should not call") end
    assert {:error, :missing_api_key} = D.evaluate("s", %{}, api_key: nil, transport: f)

    for timeout <- [0, -1, 30_001, :infinity] do
      assert {:error, :invalid_timeout} =
               D.evaluate("s", %{}, api_key: "x", timeout: timeout, transport: f)
    end

    for q <- [
          %{},
          %{"x" => D.score("?", ["one"])},
          %{"x" => D.choice("?", %{})},
          %{x: D.noul("?")}
        ] do
      assert {:error, :invalid_questions} = D.evaluate("s", q, api_key: "x", transport: f)
    end

    assert {:error, :invalid_request} =
             D.evaluate(self(), %{"n" => D.noul("?")}, api_key: "x", transport: f)
  end

  test "rejects missing, mismatched and out-of-range answers" do
    q = %{"n" => D.noul("?")}

    for a <- [
          %{},
          %{"n" => %{"type" => "noul", "noul" => 2}},
          %{"n" => %{"type" => "choice"}},
          %{"n" => %{"type" => "noul", "noul" => 0.5}, "extra" => %{}}
        ] do
      assert {:error, :invalid_response} = run(q, a)
    end

    q = %{"c" => D.choice("?", %{"a" => nil, "b" => nil})}

    for probs <- [%{"a" => 0.5}, %{"a" => 0.2, "b" => 0.2}, %{"a" => -0.1, "b" => 1.1}] do
      assert {:error, :invalid_response} =
               run(q, %{
                 "c" => %{
                   "type" => "choice",
                   "choice" => "a",
                   "confidence" => 0.5,
                   "probabilities" => probs
                 }
               })
    end
  end
end
