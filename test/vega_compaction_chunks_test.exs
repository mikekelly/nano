defmodule Vega.CompactionChunksTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    %{model: Fake.model(%{"context_length" => 8_000})}
  end

  defp requests(model, acc \\ []) do
    receive do
      {:openrouter_request, ^model, body} -> requests(model, acc ++ [body])
    after
      0 -> acc
    end
  end

  defp content(%{"content" => text}) when is_binary(text), do: text
  defp content(%{"content" => parts}), do: Enum.map_join(parts, & &1["text"])

  test "large old history is streamed in bounded UTF-8 slices with cumulative digest and aggregate usage",
       c do
    # Much larger than the conservative small model input. Individual source messages
    # are also enormous: must safely slice inside data rather than reject the record.
    old = [
      %{
        "role" => "user",
        "content" => String.duplicate("facts 猫 commitments 😀 quoted \"code\"\n", 1_500)
      }
    ]

    for stage <- 1..32,
        do:
          Fake.push(c.model,
            text: "Cumulative digest #{stage}: retain earlier commitments.",
            usage: {200, 20, 0},
            cost: 0.02
          )

    assert {:ok, final, usage} = Vega.Compaction.summarize(c.model, old, 40_000)
    bodies = requests(c.model)
    n = length(bodies)
    assert n > 2 and n < 32
    assert final =~ "digest #{n}:"
    assert usage.usage == %{"prompt_tokens" => n * 200, "completion_tokens" => n * 20}
    assert_in_delta usage.cost, n * 0.02, 0.00001

    chunks =
      Enum.map(bodies, fn body ->
        assert body["max_tokens"] == 1_000
        assert (body["tools"] || []) == []
        assert Vega.Compaction.tokens(body["messages"]) + 1_000 <= 8_000
        user = content(List.last(body["messages"]))
        chunk = user |> String.split("NEXT HISTORY SLICE (data):\n", parts: 2) |> List.last()
        assert String.valid?(chunk)
        chunk
      end)

    assert Enum.join(chunks) == Jason.encode!(old)

    for {body, i} <- Enum.with_index(bodies, 1), i > 1 do
      assert content(List.last(body["messages"])) =~ "Cumulative digest #{i - 1}:"
    end
  end

  test "ordinary full-window English prefix exceeding conservative single-call size succeeds" do
    model = Fake.model(%{"context_length" => 272_000})

    old = [
      %{
        "role" => "user",
        "content" => String.duplicate("Keep project commitments and tested code paths. ", 20_000)
      }
    ]

    assert Vega.Compaction.tokens(old) > 272_000
    for n <- 1..8, do: Fake.push(model, text: "cumulative full-window digest #{n}")
    assert {:ok, _summary, _usage} = Vega.Compaction.summarize(model, old, 272_000)
    bodies = requests(model)
    assert length(bodies) in 2..4

    for body <- bodies,
        do: assert(Vega.Compaction.tokens(body["messages"]) + body["max_tokens"] < 272_000)
  end

  test "per-call stage input tuning is bounded and requires no global setting changes", c do
    old = [%{"role" => "user", "content" => String.duplicate("commitments and facts ", 1_000)}]
    for i <- 1..32, do: Fake.push(c.model, text: "digest #{i}")

    assert {:ok, _, _} =
             Vega.Compaction.summarize(c.model, old, 40_000, stage_input_tokens: 3_000)

    bodies = requests(c.model)
    assert length(bodies) > 3
    for body <- bodies, do: assert(Vega.Compaction.tokens(body["messages"]) <= 3_200)
    assert {:error, _} = Vega.Compaction.summarize(c.model, old, 40_000, stage_input_tokens: 0)
  end

  test "later rejected stage

 returns all completed usage including rejected response",
       c do
    old = [
      %{"role" => "user", "content" => String.duplicate("ordinary English task facts ", 2_000)}
    ]

    Fake.push(c.model, text: "first digest", usage: {1_000, 20, 0}, cost: 0.01)

    Fake.push(c.model,
      text: "truncated digest",
      finish_reason: "length",
      usage: {900, 40, 0},
      cost: 0.02
    )

    assert {:error, reason, usage} = Vega.Compaction.summarize(c.model, old, 40_000)
    assert reason =~ "stage 2"
    assert usage.usage == %{"prompt_tokens" => 1_900, "completion_tokens" => 60}
    assert_in_delta usage.cost, 0.03, 0.00001
    assert length(requests(c.model)) == 2
  end

  test "later provider failure retains previous stage accounting", c do
    old = [%{"role" => "user", "content" => String.duplicate("facts ", 5_000)}]
    Fake.push(c.model, text: "first digest", usage: {500, 25, 0})
    Fake.push(c.model, status: 400)
    assert {:error, reason, usage} = Vega.Compaction.summarize(c.model, old, 40_000)
    assert reason =~ "stage 2"
    assert usage.usage == %{"prompt_tokens" => 500, "completion_tokens" => 25}
    assert length(requests(c.model)) == 2
  end
end
