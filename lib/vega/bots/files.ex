defmodule Vega.Bots.Files do
  @moduledoc "Immutable produced files. Download IDs never authorize arbitrary paths. Served as attachment/octet-stream, never executable origin content."
  @max_bytes 8_000_000
  def import(path, root) do
    with {:ok, %{type: :regular, size: size}} <- File.stat(path),
         true <- size <= @max_bytes,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_bytes do
      id = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      ref = %{
        "type" => "file_ref",
        "id" => id,
        "filename" => filename(Path.basename(path)),
        "bytes" => byte_size(bytes)
      }

      dir = Path.join([root, "bots", "files"])

      :global.trans(
        {{__MODULE__, dir, id}, self()},
        fn ->
          with :ok <- File.mkdir_p(dir) do
            target = Path.join(dir, id)

            if File.exists?(target) do
              case fetch(id, root) do
                {:ok, ^bytes, existing} -> {:ok, existing}
                _ -> {:error, :file_store_corrupt}
              end
            else
              tmp = target <> "." <> Vega.Store.id() <> ".tmp"

              result =
                with :ok <- File.write(tmp, bytes, [:binary, :sync]),
                     :ok <- File.write(target <> ".json", Jason.encode!(ref), [:binary, :sync]),
                     :ok <- File.rename(tmp, target),
                     do: {:ok, ref}

              File.rm(tmp)
              result
            end
          end
        end,
        [node()]
      )
    else
      _ -> {:error, :invalid_or_oversized_file}
    end
  end

  def fetch(id, root) when is_binary(id) do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, id),
         target = Path.join([root, "bots", "files", id]),
         {:ok, %{type: :regular, size: size}} <- File.stat(target),
         true <- size <= @max_bytes,
         {:ok, bytes} <- File.read(target),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == id,
         {:ok, metadata} <- File.read(target <> ".json"),
         {:ok, ref} <- Jason.decode(metadata),
         true <-
           ref["type"] == "file_ref" and ref["id"] == id and ref["bytes"] == byte_size(bytes),
         true <- is_binary(ref["filename"]) and ref["filename"] == filename(ref["filename"]) do
      {:ok, bytes, ref}
    else
      _ -> {:error, :file_missing_or_corrupt}
    end
  end

  def fetch(_, _), do: {:error, :invalid_file_id}

  def validate(refs, root) when is_list(refs) and length(refs) <= 4 do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      with %{"type" => "file_ref", "id" => id} <- ref, {:ok, _, canonical} <- fetch(id, root) do
        {:cont, {:ok, acc ++ [canonical]}}
      else
        _ -> {:halt, {:error, :invalid_file_ref}}
      end
    end)
  end

  def validate(_, _), do: {:error, :invalid_files}

  defp filename(name) do
    name =
      name |> String.replace(~r/[^\p{L}\p{N} ._-]/u, "_") |> String.slice(0, 120) |> String.trim()

    if name in ["", ".", ".."], do: "download", else: name
  end
end
