defmodule Vega.BotsRoutingTest.Decision do
  def evaluate(%{"message" => "Only the other bot please"}, _, _),
    do: {:ok, %{"answers" => %{"respond" => %{"noul" => 0.1}}}}

  def evaluate(_, _, _), do: {:error, :transport_error}
end

defmodule Vega.BotsRoutingTest do
  use ExUnit.Case, async: true

  test "cheap group routing skips confident irrelevant turns but defaults to answers" do
    bot = %{"id" => "a", "name" => "Muse", "description" => "Thoughtful"}
    group = %{"bot_ids" => ["a", "b"], "messages" => []}
    msg = %{"text" => "Only the other bot please"}
    opts = [api_key: "fake", decision: Vega.BotsRoutingTest.Decision]
    assert :skip == Vega.Bots.Routing.answer?(bot, group, msg, opts)
    assert :answer == Vega.Bots.Routing.answer?(bot, group, msg, api_key: nil)
    assert :answer == Vega.Bots.Routing.answer?(bot, group, %{"text" => "Everyone, help"}, opts)
    assert :answer == Vega.Bots.Routing.answer?(bot, %{group | "bot_ids" => ["a"]}, msg, opts)
  end
end
