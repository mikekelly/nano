defmodule Vega.BotsRelevanceTest.Decision do
  def evaluate(%{"message" => "a tropical holiday"}, questions, _) do
    {:ok,
     %{
       "answers" =>
         Map.new(questions, fn {id, q} ->
           {id,
            %{"noul" => if(String.contains?(q["instructions"], "pineapple"), do: 0.9, else: 0.1)}}
         end)
     }}
  end
end

defmodule Vega.BotsRelevanceTest.Failure do
  def evaluate(_, _, _), do: {:error, :transport_error}
end

defmodule Vega.BotsRelevanceTest do
  use ExUnit.Case, async: true

  test "cheap judgment selects semantically relevant bounded memories and failure falls back" do
    root = Path.join(System.tmp_dir!(), "bots-relevance-" <> Vega.Store.id())
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, relevant} = Vega.Memory.put("bot:b", "Person loves pineapple", root: root)
    {:ok, _} = Vega.Memory.put("bot:b", "Person works in accounting", root: root)

    assert {:ok, [^relevant]} =
             Vega.Bots.Relevance.retrieve("b", "a tropical holiday", root,
               api_key: "fake",
               decision: Vega.BotsRelevanceTest.Decision
             )

    assert {:ok, [^relevant]} =
             Vega.Bots.Relevance.retrieve("b", "pineapple", root,
               api_key: "fake",
               decision: Vega.BotsRelevanceTest.Failure
             )

    assert {:ok, [^relevant]} = Vega.Bots.Relevance.retrieve("b", "pineapple", root, api_key: nil)

    assert {:ok, []} =
             Vega.Bots.Relevance.retrieve("other", "pineapple", root,
               api_key: "fake",
               decision: Vega.BotsRelevanceTest.Failure
             )
  end
end
