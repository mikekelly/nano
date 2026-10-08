defmodule Vega.Bots.Persistence do
  @moduledoc false
  @max_bytes 32_000_000
  def path(root), do: Path.join([root, "bots", "c3RhdGU.json"])

  def load(root) do
    case File.stat(path(root)) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, %{type: :regular, size: size}} when size <= @max_bytes ->
        with {:ok, bytes} <- File.read(path(root)),
             {:ok, %{"version" => 1, "entries" => [data]}} <- Jason.decode(bytes),
             true <- valid?(data) do
          {:ok, data}
        else
          _ -> {:error, :corrupt_store}
        end

      {:ok, _} ->
        {:error, :store_too_large}

      error ->
        error
    end
  end

  def save(root, data) do
    path = path(root)

    with true <- valid?(data),
         {:ok, bytes} <- Jason.encode(%{"version" => 1, "entries" => [data]}),
         true <- byte_size(bytes) <= @max_bytes,
         :ok <- File.mkdir_p(Path.dirname(path)) do
      temp = path <> "." <> Vega.Store.id() <> ".tmp"
      result = with :ok <- File.write(temp, bytes, [:binary, :sync]), do: File.rename(temp, path)
      File.rm(temp)
      result
    else
      false -> {:error, :invalid_or_oversized_store}
      error -> error
    end
  end

  defp valid?(d) when is_map(d) do
    Enum.all?(~w(bots sessions requests outbox), fn k ->
      is_list(d[k]) and Enum.all?(d[k], &is_map/1)
    end) and
      is_map(d["settings"]) and
      Enum.all?(d["bots"], fn b ->
        is_binary(b["id"]) and is_binary(b["name"]) and is_map(b["face"])
      end) and
      Enum.all?(d["sessions"], fn s ->
        is_binary(s["id"]) and is_list(s["messages"]) and is_list(s["bot_ids"]) and
          is_map(s["statuses"]) and
          Enum.all?(s["statuses"], fn {bid, status} ->
            bid in s["bot_ids"] and is_map(status) and status["state"] in ~w(thinking idle error) and
              Vega.Store.text?(status["detail"], 500)
          end) and
          Enum.all?(s["messages"], fn m ->
            is_map(m) and is_binary(m["id"]) and is_binary(m["author_id"]) and
              Vega.Store.text?(m["text"], 32_000) and is_binary(m["at"]) and
              is_list(m["images"] || []) and is_list(m["files"] || [])
          end)
      end) and
      Enum.all?(d["requests"], fn r ->
        is_binary(r["id"]) and r["status"] in ~w(pending answered) and is_binary(r["requester"]) and
          request_kind_valid?(r)
      end) and
      Enum.all?(d["outbox"], fn x ->
        is_binary(x["id"]) and is_binary(x["session_id"]) and is_binary(x["bot_id"]) and
          is_binary(x["message_id"]) and is_integer(x["retry_at"])
      end) and links_valid?(d)
  end

  defp valid?(_), do: false

  defp request_kind_valid?(%{"kind" => "setting"} = r) do
    case Vega.Bots.Credentials.key(r["setting_key"]) do
      {:ok, key} ->
        key == r["setting_key"] and
          if r["status"] == "answered",
            do: r["answer"] == %{"setting_key" => key, "set" => true},
            else: is_nil(r["answer"])

      _ ->
        false
    end
  end

  defp request_kind_valid?(r), do: r["kind"] in [nil, "choice"]

  defp links_valid?(d) do
    bots = MapSet.new(Enum.map(d["bots"], & &1["id"]))
    sessions = Map.new(d["sessions"], &{&1["id"], &1})

    Enum.all?(d["sessions"], fn s -> Enum.all?(s["bot_ids"], &MapSet.member?(bots, &1)) end) and
      Enum.all?(d["requests"], fn r ->
        s = sessions[r["session_id"]]

        is_map(s) and r["bot_id"] in s["bot_ids"] and is_binary(r["question"]) and
          is_binary(r["created_at"])
      end) and
      Enum.all?(d["outbox"], fn x ->
        s = sessions[x["session_id"]]

        is_map(s) and x["bot_id"] in s["bot_ids"] and
          Enum.any?(s["messages"], &(&1["id"] == x["message_id"] and &1["author_id"] == "person"))
      end)
  end
end
