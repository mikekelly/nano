defmodule Nano.Flywheel.Bootstrap do
  @moduledoc """
  Read-only immutable bootstrap provenance importer. Freeze dispatch first, then
  capture exact original bytes/hashes. No graph-era token or stage is inferred.
  Owner imports one validated candidate and reconciles stages from retained evidence.
  state.term's synced rename is the single durable cutover; after it bootstrap files
  remain immutable provenance, never a second authority. Restart requires reconciliation.
  """
  def capture(paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, bytes} <- File.read(path),
           {:ok, record} <- Jason.decode(bytes),
           true <-
             (is_binary(record["unit"]) and record["unit"] != "" and is_binary(record["owner"]) and
                is_binary(record["incarnation"]) and
                is_integer(record["generation"]) and is_binary(record["base"]) and
                is_list(record["history"])) || {:error, :invalid_bootstrap_record} do
        item = %{
          source: path,
          sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
          original_bytes: bytes,
          record: record,
          authority_kind: :serialized_bootstrap
        }

        {:cont, {:ok, acc ++ [item]}}
      else
        e -> {:halt, e}
      end
    end)
  end

  def capture(_), do: {:error, :invalid_bootstrap_paths}
end
