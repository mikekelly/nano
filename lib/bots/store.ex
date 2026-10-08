defmodule Bots.Store do
  @moduledoc false

  def empty do
    %{
      "version" => 1,
      "bots" => %{},
      "sessions" => %{},
      "requests" => %{},
      "preferences" => %{"notifications" => false, "cooldown_seconds" => 300, "max_per_hour" => 6},
      "notification_times" => [],
      "last_notification_at" => nil
    }
  end

  def load(root) do
    with :ok <- File.mkdir_p(root) do
      case File.read(Path.join(root, "state.json")) do
        {:ok, text} ->
          with {:ok, data} <- Jason.decode(text), true <- valid?(data) do
            {:ok, data}
          else
            _ -> {:error, :invalid_bots_store}
          end

        {:error, :enoent} ->
          {:ok, empty()}

        error ->
          error
      end
    end
  end

  def save(root, data) do
    path = Path.join(root, "state.json")
    temp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    try do
      with {:ok, json} <- encode(data),
           {:ok, io} <- :file.open(String.to_charlist(temp), [:write, :binary, :exclusive]) do
        result =
          try do
            with :ok <- :file.write(io, json), do: :file.sync(io)
          after
            :file.close(io)
          end

        with :ok <- result, :ok <- File.chmod(temp, 0o600), do: File.rename(temp, path)
      end
    after
      File.rm(temp)
    end
  end

  defp encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :not_json_encodable}
    end
  end

  defp valid?(%{"version" => 1} = data) do
    Enum.all?(["bots", "sessions", "requests", "preferences"], &is_map(data[&1])) and
      is_list(data["notification_times"]) and
      Enum.all?(data["notification_times"], &(is_integer(&1) and &1 >= 0)) and
      (is_nil(data["last_notification_at"]) or natural?(data["last_notification_at"])) and
      preferences?(data["preferences"]) and
      Enum.all?(data["bots"], fn {id, bot} ->
        entity?(id, bot) and
          strings?(bot, ["name", "description", "color", "shape", "created_at"])
      end) and
      Enum.all?(data["sessions"], fn {id, session} -> session?(id, session, data["bots"]) end) and
      Enum.all?(data["requests"], fn {id, request} -> request?(id, request, data) end)
  end

  defp valid?(_), do: false

  defp entity?(id, map), do: is_binary(id) and is_map(map) and map["id"] == id
  defp strings?(map, keys), do: Enum.all?(keys, &(is_binary(map[&1]) and String.valid?(map[&1])))
  defp natural?(n), do: is_integer(n) and n >= 0

  defp preferences?(prefs) do
    is_boolean(prefs["notifications"]) and is_integer(prefs["cooldown_seconds"]) and
      prefs["cooldown_seconds"] >= 60 and prefs["max_per_hour"] in 0..60
  end

  defp session?(id, session, bots) do
    entity?(id, session) and strings?(session, ["title", "updated_at"]) and
      session["status"] in ["idle", "thinking", "stopped", "error"] and
      natural?(session["epoch"]) and natural?(session["bot_exchanges"]) and
      is_boolean(session["ceiling_noted"]) and is_list(session["bot_ids"]) and
      session["bot_ids"] != [] and Enum.all?(session["bot_ids"], &Map.has_key?(bots, &1)) and
      is_list(session["pending_human_ids"]) and
      Enum.all?(session["pending_human_ids"], &is_binary/1) and
      is_list(session["messages"]) and Enum.all?(session["messages"], &message?/1) and
      is_list(Map.get(session, "pending_speakers", [])) and
      Enum.all?(Map.get(session, "pending_speakers", []), &(&1 in session["bot_ids"])) and
      (Map.get(session, "pending_speakers", []) == [] or
         Enum.any?(session["messages"], &(&1["id"] == session["pending_message_id"])))
  end

  defp message?(message) when is_map(message) do
    strings?(message, ["id", "kind", "text", "created_at"]) and
      message["kind"] in ["human", "bot", "system", "request"] and
      (is_nil(message["bot_id"]) or is_binary(message["bot_id"])) and
      (is_nil(message["request_id"]) or is_binary(message["request_id"])) and
      is_list(message["attachments"]) and Enum.all?(message["attachments"], &is_map/1)
  end

  defp message?(_), do: false

  defp request?(id, request, data) do
    entity?(id, request) and strings?(request, ["bot_id", "session_id", "text", "created_at"]) and
      Map.has_key?(data["bots"], request["bot_id"]) and
      Map.has_key?(data["sessions"], request["session_id"]) and
      request["status"] in ["pending", "answered", "delivered"] and is_map(request["requester"]) and
      (is_nil(request["answer"]) or is_binary(request["answer"]))
  end
end
