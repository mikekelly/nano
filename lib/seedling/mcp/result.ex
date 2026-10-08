defmodule Seedling.MCP.Result do
  @moduledoc false
  def bound(value, max_bytes, dir) do
    json = Jason.encode!(value, pretty: true)
    limit = min(max(max_bytes, 256), 32_768)

    if byte_size(json) <= limit do
      {:ok, value}
    else
      with :ok <- File.mkdir_p(dir),
           path =
             Path.join(
               dir,
               Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <> ".json"
             ),
           :ok <- File.write(path, json, [:exclusive]) do
        {:ok,
         %{
           truncated: true,
           path: path,
           bytes: byte_size(json),
           preview: prefix(json, min(limit, 1024))
         }}
      else
        error -> {:error, {:spill_failed, error}}
      end
    end
  end

  def page(path, opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = min(max(Keyword.get(opts, :limit, 4096), 4), 16_384)

    if is_integer(offset) and offset >= 0 do
      with {:ok, io} <- File.open(path, [:read, :binary]) do
        try do
          case :file.pread(io, offset, limit + 4) do
            :eof ->
              {:ok, %{text: "", next_offset: nil}}

            {:ok, bytes} ->
              text = prefix(bytes, limit)

              if text == "" or not String.valid?(text), do: throw(:unaligned_utf8_offset)

              {:ok,
               %{
                 text: text,
                 next_offset:
                   if(byte_size(bytes) > byte_size(text), do: offset + byte_size(text), else: nil)
               }}

            error ->
              error
          end
        catch
          :unaligned_utf8_offset -> {:error, :unaligned_utf8_offset}
        after
          File.close(io)
        end
      end
    else
      {:error, :invalid_offset}
    end
  end

  defp prefix(_, 0), do: ""
  defp prefix(text, limit) when byte_size(text) <= limit, do: text

  defp prefix(text, limit) do
    bytes = binary_part(text, 0, limit)
    if String.valid?(bytes), do: bytes, else: prefix(text, limit - 1)
  end
end
