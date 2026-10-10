defmodule Nano.MCP.Page do
  @moduledoc """
  Bounded MCP results. Small JSON values stay structured; values over 8 KiB are
  stored as pretty JSON and return a bounded text page with a durable ID. `read/2`
  uses Nano.Tools line paging. Binary MCP content is retained as base64 in JSON.
  Results are private to this trusted local node, not a public file service.
  """
  def root, do: Path.join(Application.fetch_env!(:nano, :spill_dir), "mcp")

  def bound(value) do
    do_bound(value)
  rescue
    _ ->
      %{
        cut: true,
        error: :spill_failed,
        text: "MCP result could not be stored; check the spill directory and retry."
      }
  end

  defp do_bound(value) do
    bytes = Jason.encode!(value, pretty: true)

    if byte_size(bytes) <= 8192 do
      %{data: value, cut: false}
    else
      id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      File.mkdir_p!(root())
      path = Path.join(root(), id <> ".json")
      File.write!(path, bytes)
      view = Path.join(root(), id <> ".txt")
      # A JSON string/base64 blob can be one huge line. Keep original JSON intact,
      # and wrap only the display view so Nano.Tools can page it with bounded lines.
      File.write!(view, Regex.replace(~r/([^\n]{1000})/u, bytes, "\\1\n"))
      {:ok, page} = Nano.Tools.read(view, limit: 60, max_bytes: 4096)
      prune()

      Map.merge(page, %{
        id: id,
        raw_path: path,
        display_wrapped: true,
        bytes: byte_size(bytes),
        cut: true,
        continuation: "Nano.MCP.page(#{inspect(id)}, offset: #{page.next_offset || 1})"
      })
    end
  end

  @doc "Remove oldest stored pages beyond 128 MiB or seven days; returned IDs may expire."
  def prune do
    cutoff = System.os_time(:second) - 7 * 86400

    files =
      Path.wildcard(Path.join(root(), "*.json"))
      |> Enum.flat_map(fn path ->
        case File.stat(path, time: :posix) do
          {:ok, stat} ->
            view = Path.rootname(path) <> ".txt"

            size =
              stat.size +
                case File.stat(view) do
                  {:ok, v} -> v.size
                  _ -> 0
                end

            [{path, view, stat.mtime, size}]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(&elem(&1, 2))

    total = Enum.reduce(files, 0, fn {_, _, _, size}, acc -> acc + size end)

    Enum.reduce(files, total, fn {path, view, mtime, size}, remaining ->
      if mtime < cutoff or remaining > 128 * 1024 * 1024 do
        File.rm(path)
        File.rm(view)
        remaining - size
      else
        remaining
      end
    end)

    :ok
  end

  def read(
        id,
        opts \\ []
      ) do
    if is_binary(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id) do
      Nano.Tools.read(
        Path.join(root(), id <> ".txt"),
        Keyword.merge([limit: 100, max_bytes: 8192], opts)
        |> Keyword.update(:max_bytes, 8192, &min(&1, 8192))
        |> Keyword.update(:limit, 100, &min(&1, 100))
      )
    else
      {:error, :invalid_page_id}
    end
  end
end
