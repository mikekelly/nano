defmodule Nano.BotsContextTest do
  use ExUnit.Case, async: true

  test "aggregate delivery cannot flood a new generation" do
    chat = %{
      id: "s",
      brief: String.duplicate("🧠", 12000),
      messages: for(_ <- 1..12, do: %{who: :human, text: String.duplicate("hotel x", 4500)})
    }

    memories = for(_ <- 1..6, do: %{text: "hotel " <> String.duplicate("x", 31990), at: 0})
    payload = Nano.Bots.Runtime.payload(%{}, chat, String.duplicate("hotel x", 4500), memories)
    assert byte_size(Jason.encode!(payload)) <= 12000
    assert :erlang.external_size(payload) < 16000
    assert String.valid?(payload.human)
  end

  test "Unicode and escaped controls are bounded by bytes" do
    assert byte_size(Nano.Bots.Context.clip(String.duplicate("🧠", 100), 15)) <= 15
    assert String.valid?(Nano.Bots.Context.clip(String.duplicate("🧠", 100), 15))

    s = %{
      name: "test",
      system_prompt: "lean",
      max_context: 32000,
      context_used: 30000,
      estimate: 30000,
      transcript: [
        %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "answered"}]},
        %{
          "role" => "tool",
          "tool_call_id" => "answered",
          "content" => String.duplicate("\u0001🧠", 20000)
        }
      ]
    }

    {:replace_transcript, replacement} = Nano.Bots.Context.before_request(s)
    assert byte_size(Jason.encode!(replacement)) <= 12000
    assert Enum.all?(replacement, &(Map.keys(&1) |> Enum.sort() == ["content", "role"]))
    assert Enum.all?(replacement, &String.valid?(&1["content"]))
  end

  test "small contexts are kept unchanged" do
    assert :keep =
             Nano.Bots.Context.before_request(%{
               system_prompt: "lean",
               max_context: 32000,
               context_used: 0,
               estimate: 20,
               transcript: [%{"role" => "user", "content" => "hello"}]
             })
  end
end
