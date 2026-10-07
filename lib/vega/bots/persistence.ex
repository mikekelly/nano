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
          is_map(s["statuses"])
      end) and
      Enum.all?(d["requests"], fn r ->
        is_binary(r["id"]) and r["status"] in ~w(pending answered) and is_binary(r["requester"])
      end) and
      Enum.all?(d["outbox"], fn x ->
        is_binary(x["id"]) and is_binary(x["session_id"]) and is_binary(x["bot_id"]) and
          is_binary(x["message_id"]) and is_integer(x["retry_at"])
      end)
  end

  defp valid?(_), do: false
end
