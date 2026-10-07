defmodule Seedling.BotArtifacts do
  @moduledoc "Bounded produced-file copies for the trusted-local bots UI, not a sandbox."
  @limit 2 * 1024 * 1024
  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id)

  def root,
    do:
      Path.expand(
        Application.get_env(
          :nano,
          :bot_artifacts_root,
          Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "bot_artifacts")
        )
      )

  def store(path) when is_binary(path) do
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    base = root()
    tmp = Path.join(base, ".#{id}.tmp")
    dest = Path.join(base, id)

    result =
      with :ok <- File.mkdir_p(base),
           :ok <- no_symlinks(base),
           {:ok, bytes} <- read_regular(path),
           :ok <- durable_write(tmp, bytes),
           :ok <- File.rename(tmp, dest) do
        {:ok, %{"id" => id, "filename" => filename(path), "size" => byte_size(bytes)}}
      end

    File.rm(tmp)
    result
  end

  def store(_), do: {:error, :invalid_path}

  def remove(%{"id" => id}) do
    if valid_id?(id) and no_symlinks(root()) == :ok, do: File.rm(Path.join(root(), id))
    :ok
  end

  def fetch(id) do
    if valid_id?(id) do
      with :ok <- no_symlinks(root()), do: read_regular(Path.join(root(), id))
    else
      {:error, :invalid_id}
    end
  end

  defp filename(path) do
    name = Path.basename(path)

    if String.valid?(name) do
      name |> String.replace(~r/[^a-zA-Z0-9._ -]/u, "_") |> String.slice(0, 120)
    else
      "download"
    end
  end

  # Reject symlinks in every component, including the leaf. no_follow also
  # protects the leaf between lstat and open. Privileged concurrent parent
  # replacement is outside this trusted-local service's security boundary.
  defp no_symlinks(path) do
    Path.expand(path)
    |> Path.split()
    |> Enum.reduce_while("", fn part, parent ->
      current = if parent == "", do: part, else: Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink}}
        {:ok, _} -> {:cont, current}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      error -> error
    end
  end

  defp read_regular(path) do
    with :ok <- no_symlinks(path),
         {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :raw, :binary, :no_follow]) do
      try do
        case :file.read_file_info(io) do
          {:ok, info} when elem(info, 2) == :regular -> read_chunks(io, [], 0)
          _ -> {:error, :not_regular}
        end
      after
        :file.close(io)
      end
    else
      {:ok, _} -> {:error, :not_regular}
      error -> error
    end
  end

  defp read_chunks(io, chunks, size) do
    case :file.read(io, min(64 * 1024, @limit - size + 1)) do
      :eof ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

      {:ok, bytes} when size + byte_size(bytes) <= @limit ->
        read_chunks(io, [bytes | chunks], size + byte_size(bytes))

      {:ok, _} ->
        {:error, :too_large}

      error ->
        error
    end
  end

  defp durable_write(path, bytes) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:write, :raw, :binary, :exclusive]) do
      try do
        with :ok <- :file.write(io, bytes), do: :file.sync(io)
      after
        :file.close(io)
      end
    end
  end
end
