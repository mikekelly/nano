defmodule Nano.MCP.Result do
  @moduledoc "Bounded MCP JSON results. Spill files can be paged with `page/2`."
  def bound(result, opts \\ []) do
    bytes = Jason.encode!(result)
    limit = max(1, Keyword.get(opts, :max_bytes, 16_384))

    if byte_size(bytes) <= limit do
      {:ok, result}
    else
      dir = Keyword.get(opts, :spill_dir, Path.join(System.tmp_dir!(), "nano-mcp-results"))

      path =
        Path.join(
          dir,
          Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <> ".json"
        )

      with :ok <- File.mkdir_p(dir), :ok <- File.write(path, bytes, [:exclusive]) do
        File.chmod(path, 0o600)

        {:ok,
         %{
           spilled: true,
           path: path,
           bytes: byte_size(bytes),
           preview: binary_part(bytes, 0, min(limit, 2_000))
         }}
      end
    end
  end

  def page(path, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 8_192) |> min(50_000) |> max(1)

    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary]) do
      result = :file.pread(file, offset, limit)
      :file.close(file)

      case result do
        {:ok, bytes} -> {:ok, %{data: bytes, next_offset: offset + byte_size(bytes)}}
        :eof -> {:ok, :eof}
        error -> error
      end
    end
  end
end
