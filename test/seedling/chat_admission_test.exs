defmodule Seedling.ChatAdmissionTest do
  use ExUnit.Case, async: true
  alias Seedling.ChatContext

  test "long multibyte chat fits actual context and new human request is prioritized" do
    messages =
      for i <- 1..24,
          do: %{
            "id" => to_string(i),
            "speaker" => "human",
            "text" => String.duplicate("界\"", 12000),
            "at" => "now",
            "files" => []
          }

    latest = List.last(messages)
    chat = %{"id" => "session", "messages" => messages}
    bot = %{"id" => "bot", "max_context" => 64000}
    memory = %{text: String.duplicate("界", 1600), method: :jev}
    info = %{system_prompt: "lean prompt", budget: %{max_context: 64000}}
    assert {:ok, cap} = ChatContext.admission(info, bot, 3)

    event =
      ChatContext.build(
        chat,
        bot,
        "CURRENT REQUEST " <> latest["text"],
        memory,
        :one_to_one,
        latest
      )

    assert {:ok, fitted} = ChatContext.fit(event, cap)
    assert fitted.message =~ "CURRENT REQUEST"
    assert String.valid?(fitted.message)
    assert byte_size(inspect(fitted, limit: :infinity, printable_limit: :infinity)) <= cap
    assert byte_size(ChatContext.serialize(fitted)) <= 40000
    assert ChatContext.serialize(fitted) =~ "Truncated"
    # Four large images cannot fit in the safe retained-turn quarter of a 64k window.
    assert {:error, :chat_or_images_exceed_context_budget} = ChatContext.admission(info, bot, 4)
  end

  test "actual window, not configured larger bot window, controls admission" do
    bot = %{"max_context" => 64000}
    tiny = %{system_prompt: String.duplicate("x", 5000), budget: %{max_context: 8192}}
    assert {:error, :chat_or_images_exceed_context_budget} = ChatContext.admission(tiny, bot, 1)
    assert {:error, :chat_or_images_exceed_context_budget} = ChatContext.admission(tiny, bot, 0)

    assert {:ok, cap} =
             ChatContext.admission(
               %{system_prompt: "short", budget: %{max_context: 16384}},
               bot,
               0
             )

    assert cap <= div(16384, 4) * 2
  end
end
