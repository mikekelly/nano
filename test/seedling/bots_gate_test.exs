defmodule Seedling.Bots.GateTest do
  use ExUnit.Case, async: true
  alias Seedling.Bots.Gate

  defmodule Decision do
    def probability(_, _, _), do: {:ok, %{probability: 0.7, model: "jev", usage: %{}}}

    def evaluate(_, _, _),
      do:
        {:ok,
         %{
           answers: %{
             "memory_0" => %{"type" => "noul", "noul" => 0.9},
             "memory_1" => %{"type" => "noul", "noul" => 0.3}
           },
           model: "jev",
           usage: %{}
         }}
  end

  defmodule Unavailable do
    def probability(_, _, _), do: {:error, :missing_credentials}
    def evaluate(_, _, _), do: {:error, :transport_failed}
  end

  defmodule Invalid do
    def probability(_, _, _), do: {:ok, %{probability: 2}}
    def evaluate(_, _, _), do: {:ok, %{answers: %{"memory_0" => "invalid", "memory_1" => 1.1}}}
  end

  test "reply gates grow stricter and degrade conservatively" do
    bot = %{"name" => "Muse"}
    session = %{"bots" => ["Muse", "Dots"], "exchanges" => 0, "messages" => []}
    bot_msg = %{"from" => "Dots", "text" => "I have an idea"}
    assert Gate.reply?(bot, session, bot_msg, decision: Decision)
    refute Gate.reply?(bot, Map.put(session, "exchanges", 5), bot_msg, decision: Decision)
    refute Gate.reply?(bot, session, bot_msg, decision: Unavailable)
    assert Gate.reply?(bot, session, Map.put(bot_msg, "from", "human"), decision: Unavailable)
    refute Gate.reply?(bot, session, bot_msg, decision: Invalid)
  end

  test "typed memory relevance is selective; fallback does not dump unrelated memory" do
    candidates = [
      %{"id" => "1", "text" => "Quiet hotels", "tags" => ["travel"]},
      %{"id" => "2", "text" => "Cat Kiwi", "tags" => ["pets"]}
    ]

    bot = %{"name" => "Muse"}
    message = %{"text" => "Find accommodation"}
    assert [%{"id" => "1"}] = Gate.memories(bot, message, candidates, decision: Decision)
    assert [] = Gate.memories(bot, message, candidates, decision: Unavailable)

    assert [%{"id" => "2"}] =
             Gate.memories(bot, %{"text" => "Cat name"}, candidates, decision: Unavailable)

    assert [] = Gate.memories(bot, message, candidates, decision: Invalid)
  end

  test "Markdown escapes HTML, active URLs and fenced contents, allows safe markup only" do
    html =
      SeedlingWeb.BotComponents.markdown(
        "# Hello\n**bold** *em* `x<y`\n[ok](https://example.com)\n[bad](javascript:alert(1))\n<script onclick='x'>oops</script>\n```html\n<img src=x onerror=alert(1)>\n```"
      )
      |> Phoenix.HTML.safe_to_string()

    assert html =~ "<h2>Hello</h2>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<code>x&lt;y</code>"
    assert html =~ "rel=\"noopener noreferrer\""
    refute html =~ "href=\"javascript:"
    refute html =~ "<script"
    refute html =~ "<img"
    assert html =~ "&lt;img"
  end
end
