defmodule Nano.Bots.PromptTest do
  use ExUnit.Case, async: true

  test "conversational identity, publication and live retention without transcript leakage" do
    bot = %{id: "mira", name: "Mira", voice: "Dry wit", description: "Curious"}
    session = %{id: "session", transcript: "SECRET TRANSCRIPT"}

    records = [
      %{bot_id: "other", text: "OTHER PRIVATE", provenance: %{}},
      %{bot_id: "mira", text: "Prefers trains", provenance: %{message_id: "source"}}
    ]

    job =
      Nano.Bots.Prompt.job(bot, session,
        memories: records,
        publication: "Runtime.post with turn token"
      )

    for text <- [
          "Dry wit",
          "first reply",
          "Stay quiet",
          "untrusted data",
          "explicitly post",
          "Runtime.post",
          "Compaction is live",
          "preferences",
          "decisions",
          "commitments",
          "unresolved questions",
          "source",
          "Prefers trains",
          "DATA ONLY",
          "Nano.Web",
          "Nano.Search",
          "Nano.Images",
          "Nano.MCP",
          "Goals",
          "FrontMind",
          "Memory.remember"
        ],
        do: assert(job =~ text)

    refute job =~ "SECRET TRANSCRIPT"
    refute job =~ "OTHER PRIVATE"
  end

  test "prompt memory is bounded and oversized records excluded" do
    bot = %{id: "mira", name: "Mira"}
    records = for _ <- 1..50, do: %{bot_id: "mira", text: "unique fact", provenance: %{}}
    job = Nano.Bots.Prompt.job(bot, %{id: "s"}, memories: records)
    assert length(Regex.scan(~r/unique fact/, job)) == 8
    big = %{bot_id: "mira", text: String.duplicate("OVERSIZE", 1000), provenance: %{}}
    refute Nano.Bots.Prompt.job(bot, %{id: "s"}, memories: [big]) =~ "OVERSIZE"
  end
end
