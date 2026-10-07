defmodule Vega.Bots.Context do
  @moduledoc "Bounded shared context from exactly one session, never another pair's private transcript. Peer posts become context on the next person turn, not autonomous wakeups."
  @max_records 20
  @max_bytes 8000
  @text_bytes 1000
  def recent(session, input_id) do
    candidates = Enum.reject(session["messages"], &(&1["id"] == input_id))
    names = Map.new(session["routing_participants"] || [], &{&1["id"], &1["name"]})
    total_prior = session["prior_message_count"] || length(candidates)

    records =
      Enum.map(Enum.take(candidates, -@max_records), fn m ->
        text = truncate(m["text"] || "", @text_bytes)

        m
        |> Map.take(~w(id author_id at reply_to request_id images files))
        |> Map.put(
          "author_name",
          if(m["author_id"] == "person", do: "You", else: Map.get(names, m["author_id"], "Bot"))
        )
        |> Map.put("text", text)
        |> Map.put("text_truncated", text != m["text"])
        |> Map.put("original_text_bytes", byte_size(m["text"] || ""))
      end)

    {selected, _} =
      Enum.reduce_while(Enum.reverse(records), {[], 2}, fn record, {acc, bytes} ->
        size = byte_size(Jason.encode!(record)) + if(acc == [], do: 0, else: 1)

        if length(acc) < @max_records and bytes + size <= @max_bytes,
          do: {:cont, {[record | acc], bytes + size}},
          else: {:halt, {acc, bytes}}
      end)

    %{
      "recent_messages" => selected,
      "recent_messages_meta" => %{
        "session_id" => session["id"],
        "total_prior_messages" => total_prior,
        "included_messages" => length(selected),
        "omitted_older_messages" => total_prior - length(selected),
        "text_truncation_bytes" => @text_bytes,
        "max_records" => @max_records,
        "max_bytes" => @max_bytes,
        "before_cursor" =>
          case selected do
            [first | _] -> first["id"]
            _ -> input_id
          end,
        "retrieval" =>
          "Vega.Bots.get_session(session_id, before: before_cursor, limit: 80); each record id can be fetched fully via Vega.Bots.get_message(session_id, message_id)."
      }
    }
  end

  defp truncate(text, cap) when byte_size(text) <= cap, do: text

  defp truncate(text, cap) do
    {parts, _} =
      Enum.reduce_while(String.graphemes(text), {[], 0}, fn part, {acc, n} ->
        if n + byte_size(part) <= cap,
          do: {:cont, {[part | acc], n + byte_size(part)}},
          else: {:halt, {acc, n}}
      end)

    parts |> Enum.reverse() |> Enum.join()
  end
end
