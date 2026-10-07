defmodule Nano.Bots.Files do
  @moduledoc "Bounded private artifact copying. No model-authored URL/path is ever used by the browser."
  @max 5_000_000
  def store(root, source, filename) when is_binary(source) do
    with {:ok, %{type: :regular, size: size}} when size <= @max <- File.lstat(source),
         {:ok, io} <- File.open(source, [:read, :binary]) do
      bytes =
        try do
          IO.binread(io, @max + 1)
        after
          File.close(io)
        end

      bytes = if bytes == :eof, do: "", else: bytes

      if is_binary(bytes) and byte_size(bytes) <= @max do
        id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        path = Path.join(root, id <> ".data")

        with :ok <- File.mkdir_p(root),
             :ok <- File.chmod(root, 0o700),
             :ok <- File.write(path, bytes, [:exclusive]),
             :ok <- File.chmod(path, 0o600) do
          {:ok,
           %{
             id: id,
             filename: filename(filename || Path.basename(source)),
             size: byte_size(bytes)
           }, path}
        end
      else
        {:error, :file_too_large}
      end
    else
      {:ok, %{type: :regular}} -> {:error, :file_too_large}
      {:ok, _} -> {:error, :not_a_regular_file}
      error -> error
    end
  end

  def store(_, _, _), do: {:error, :invalid_path}

  defp filename(value) when is_binary(value) do
    name = value |> String.replace(~r/[\x00-\x1f\x7f\/\\]/u, "_") |> Nano.Bots.Context.clip(120)
    if String.trim(name) == "", do: "download.data", else: name
  end

  defp filename(_), do: "download.data"
end
