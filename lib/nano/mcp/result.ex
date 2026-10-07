defmodule Nano.MCP.Result do
  @moduledoc """
  Bounded MCP JSON results. Spill files can be paged with `page/2`.
  JSON output is capped at 24,000 bytes even with larger requested budgets;
  unbounded `inspect` output is also checked against 32,000 bytes.
  Binary pages are at most 4,096 bytes, keeping worst-case inspected output
  safely below the harness cap. Options must be positive integer budgets.
  """
  @max_json 24_000
  @max_inspected 32_000
  @max_page 4_096

  def bound(result, opts \\ []) do
    with :ok <- options(opts),
         {:ok, bytes} <- Jason.encode(result) do
      limit = min(Keyword.get(opts, :max_bytes, 16_384), @max_json)

      if byte_size(bytes) <= limit and inspected_size(result) <= @max_inspected do
        {:ok, result}
      else
        spill(bytes, limit, opts)
      end
    else
      {:error, %Jason.EncodeError{}} -> {:error, :not_json_encodable}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_result}
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and positive?(Keyword.get(opts, :max_bytes, 16_384)) and
         path?(Keyword.get(opts, :spill_dir, System.tmp_dir!())) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp options(_), do: {:error, :invalid_options}
  defp positive?(n), do: is_integer(n) and n > 0
  defp path?(p), do: is_binary(p) and byte_size(p) > 0 and not String.contains?(p, <<0>>)

  defp inspected_size(result),
    do: byte_size(inspect(result, limit: :infinity, printable_limit: :infinity))

  defp spill(bytes, limit, opts) do
    dir = Keyword.get(opts, :spill_dir, Path.join(System.tmp_dir!(), "nano-mcp-results"))

    path =
      Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <> ".json")

    # Establish permissions before writing the result, not after.
    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, "", [:exclusive]),
         :ok <- File.chmod(path, 0o600),
         :ok <- File.write(path, bytes) do
      {:ok,
       %{
         spilled: true,
         path: path,
         bytes: byte_size(bytes),
         preview: prefix(bytes, min(limit, 2_000))
       }}
    end
  end

  defp prefix(bytes, size) do
    candidate = binary_part(bytes, 0, size)
    if String.valid?(candidate), do: candidate, else: prefix(bytes, size - 1)
  end

  def page(path, opts \\ []) do
    if path?(path) and is_list(opts) and Keyword.keyword?(opts) and
         is_integer(Keyword.get(opts, :offset, 0)) and Keyword.get(opts, :offset, 0) >= 0 and
         positive?(Keyword.get(opts, :limit, @max_page)) do
      offset = Keyword.get(opts, :offset, 0)
      limit = min(Keyword.get(opts, :limit, @max_page), @max_page)

      with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary]) do
        result = :file.pread(file, offset, limit)
        :file.close(file)

        case result do
          {:ok, bytes} -> {:ok, %{data: bytes, next_offset: offset + byte_size(bytes)}}
          :eof -> {:ok, :eof}
          error -> error
        end
      end
    else
      {:error, :invalid_options}
    end
  end
end
