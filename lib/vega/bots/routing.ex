defmodule Vega.Bots.Routing do
  @moduledoc "Optional cheap typed group-turn routing. Ambiguous, missing-key and provider-failure cases conservatively let each bot respond; no name keyword heuristics."
  def answer?(bot, session, message, opts \\ []) do
    if length(session["bot_ids"]) <= 1 do
      :answer
    else
      key =
        Keyword.get_lazy(opts, :api_key, fn ->
          Nano.Settings.get("TYPESAFE_API_KEY") || System.get_env("TYPESAFE_API_KEY")
        end)

      if is_binary(key) and key != "" do
        decision = Keyword.get(opts, :decision, Vega.Decision)

        state = %{
          "message" => message["text"],
          "bot" => Map.take(bot, ~w(id name description)),
          "participants" => session["routing_participants"] || session["bot_ids"],
          "recent_conversation" =>
            Enum.take(session["messages"], -4) |> Enum.map(&Map.take(&1, ~w(author_id text)))
        }

        question = %{
          "respond" => %{
            "type" => "noul",
            "instructions" =>
              "Probability this bot should respond now in the group conversation. Respond if addressed, asked to help with the shared problem, or all bots are invited. Do not respond if the person explicitly requests only another participant or requests silence. When ambiguous prefer responding. This judges whether a turn is warranted, not the response content."
          }
        }

        case decision.evaluate(state, question, api_key: key, timeout: 3000) do
          {:ok, %{"answers" => %{"respond" => %{"noul" => score}}}}
          when is_number(score) and score >= 0 and score < 0.25 ->
            :skip

          _ ->
            :answer
        end
      else
        :answer
      end
    end
  end
end
