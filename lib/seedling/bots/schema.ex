defmodule Seedling.Bots.Schema do
  @moduledoc false
  # Fail closed on corrupt saved shapes: silently resetting would replace an identity.
  def valid?(data) do
    maps = ~w(bots sessions memories requests attachments config)

    Enum.all?(maps, &is_map(data[&1])) and
      Enum.all?(data["bots"], fn {id, b} ->
        b["id"] == id and Enum.all?(~w(name description voice color), &string?(b[&1])) and
          b["shape"] in 0..2 and integer?(b["created_at"])
      end) and
      Enum.all?(data["sessions"], fn {id, s} ->
        s["id"] == id and string?(s["title"]) and strings?(s["bots"]) and
          length(s["bots"]) in 1..8 and Enum.all?(s["bots"], &Map.has_key?(data["bots"], &1)) and
          is_list(s["messages"]) and Enum.all?(s["messages"], &message?(&1, s, data)) and
          integer?(s["created_at"]) and integer?(s["updated_at"]) and integer?(s["exchanges"]) and
          integer?(s["epoch"]) and is_boolean(s["paused"]) and preferences?(s["notifications"]) and
          is_list(s["notification_times"]) and Enum.all?(s["notification_times"], &integer?/1)
      end) and
      Enum.all?(data["memories"], fn {bid, ms} ->
        Map.has_key?(data["bots"], bid) and is_list(ms) and
          Enum.all?(ms, fn m ->
            string?(m["id"]) and string?(m["text"]) and strings?(m["tags"]) and integer?(m["at"])
          end)
      end) and
      Enum.all?(data["requests"], fn {id, r} ->
        r["id"] == id and Map.has_key?(data["bots"], r["bot"]) and
          Map.has_key?(data["sessions"], r["session"]) and string?(r["question"]) and
          target?(r["reply_to"]) and integer?(r["created_at"]) and integer?(r["expires_at"]) and
          r["state"] in ~w(pending answered delivered cancelled expired) and
          (r["state"] not in ~w(answered delivered) or string?(r["answer"]))
      end) and
      Enum.all?(data["attachments"], fn {id, a} ->
        a["id"] == id and Regex.match?(~r/\A[A-Za-z0-9_-]{16}\z/, id) and string?(a["name"]) and
          integer?(a["bytes"]) and a["bytes"] <= 10_000_000 and string?(a["type"])
      end)
  rescue
    _ -> false
  end

  defp message?(m, s, data),
    do:
      string?(m["id"]) and string?(m["name"]) and string?(m["text"]) and
        m["from"] in ["human", "system" | s["bots"]] and integer?(m["at"]) and
        strings?(m["attachments"]) and
        Enum.all?(m["attachments"], &Map.has_key?(data["attachments"], &1)) and
        is_boolean(m["notify"])

  defp preferences?(p),
    do: is_boolean(p["enabled"]) and p["per_hour"] in 0..30 and p["cooldown_seconds"] in 0..86400

  defp target?(%{"kind" => "agent", "name" => name}), do: string?(name)
  defp target?(%{"kind" => "pid", "pid" => pid}), do: string?(pid)
  defp target?(_), do: false
  defp string?(v), do: is_binary(v) and String.valid?(v)
  defp strings?(v), do: is_list(v) and Enum.all?(v, &string?/1)
  defp integer?(v), do: is_integer(v) and v >= 0
end
