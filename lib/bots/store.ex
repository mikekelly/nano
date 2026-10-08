defmodule Bots.Store do
  @moduledoc false

  def empty do
    %{
      "version" => 1,
      "bots" => %{},
      "sessions" => %{},
      "requests" => %{},
      "preferences" => %{"notifications" => false, "cooldown_seconds" => 300, "max_per_hour" => 6},
      "notification_times" => []
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

    result =
      with {:ok, io} <- :file.open(String.to_charlist(temp), [:write, :binary, :exclusive]) do
        result = with :ok <- :file.write(io, Jason.encode!(data)), do: :file.sync(io)
        :file.close(io)
        with :ok <- result, :ok <- File.chmod(temp, 0o600), do: File.rename(temp, path)
      end

    if result != :ok, do: File.rm(temp)
    result
  end

  defp valid?(%{"version" => 1} = data) do
    Enum.all?(["bots", "sessions", "requests", "preferences"], &is_map(data[&1])) and
      is_list(data["notification_times"])
  end

  defp valid?(_), do: false
end
