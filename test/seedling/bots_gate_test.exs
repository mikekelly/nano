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

  defmodule NeverCalled do
    def probability(_, _, _), do: raise("single direct chat must not call a classifier")
  end

  defmodule InspectDecision do
    def probability(state, instructions, _) do
      send(self(), {:gate_state, Jason.decode!(state), instructions})
      {:ok, %{probability: 0.9}}
    end
  end

  test "a person's direct sole-bot request cannot be silently vetoed by a cheap classifier" do
    assert Gate.reply?(
             %{"id" => "muse"},
             %{"bots" => ["muse"], "exchanges" => 0, "messages" => []},
             %{"from" => "human", "text" => "Please remember quiet hotels"},
             decision: NeverCalled
           )
  end

  test "group gate includes bot identity, treats explicit human requests distinctly and excludes duplicate current message" do
    bot = %{"id" => "muse", "name" => "Muse"}
    previous = %{"id" => "1", "from" => "dots", "text" => "An earlier suggestion"}
    current = %{"id" => "2", "from" => "human", "text" => "Muse and Dots, each say hello"}
    session = %{"bots" => ["muse", "dots"], "exchanges" => 0, "messages" => [previous, current]}
    assert Gate.reply?(bot, session, current, decision: InspectDecision)
    assert_receive {:gate_state, state, instructions}
    assert state["bot"]["id"] == "muse"
    assert [%{"text" => "An earlier suggestion"}] = state["recent"]
    assert instructions =~ "explicit human request"
    assert instructions =~ "bot repetition"
  end
end
