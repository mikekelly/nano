defmodule Seedling.Web.Store do
  @moduledoc false
  alias Seedling.Files
  alias Seedling.Web.HTTP

  def root(opts), do: Keyword.get(opts, :cache_dir, "/tmp/seedling-web-cache")
  def id(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  def put(text, meta, opts) when is_binary(text) and is_map(meta) do
    if String.valid?(text) do
      root = root(opts)
      key = id((meta[:url] || "") <> "\n" <> text)

      meta =
        meta
        |> Map.update(:title, "", &clip(&1 || "", 300))
        |> Map.update(:url, "", &clip(&1 || "", 8000))

      metadata =
        Map.merge(meta, %{
          id: key,
          fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          stored_at: System.system_time(:second),
          bytes: byte_size(text),
          sha256: id(text)
        })

      with {:ok, _} <- Files.write(Path.join(root, key <> ".txt"), text),
           {:ok, _} <- Files.write(Path.join(root, key <> ".json"), Jason.encode!(metadata)) do
        prune(opts, key)
        {:ok, metadata}
      end
    else
      HTTP.error(:encoding, "Content is not UTF-8; convert it before storing.")
    end
  end

  def meta(key, opts) do
    with :ok <- valid_id(key),
         {:ok, raw} <- File.read(Path.join(root(opts), key <> ".json")),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, data}
    else
      {:error, %{reason: _}} = error -> error
      _ -> HTTP.error(:cache_miss, "Content is absent or corrupt; fetch it again.")
    end
  end

  def text(key, opts) do
    with :ok <- valid_id(key),
         {:ok, text} <- File.read(Path.join(root(opts), key <> ".txt")) do
      {:ok, text}
    else
      {:error, %{reason: _}} = error -> error
      _ -> HTTP.error(:cache_miss, "Stored content is absent; fetch it again.")
    end
  end

  def read(key, opts) do
    offset = Keyword.get(opts, :offset, 0)
    cap = Keyword.get(opts, :max_bytes, 12_000)

    with :ok <- options(opts),
         :ok <- page_options(offset, cap),
         {:ok, meta} <- meta(key, opts),
         {:ok, text} <- text(key, opts) do
      cond do
        offset > byte_size(text) ->
          HTTP.error(:offset, "Offset is past the end (#{byte_size(text)} bytes); use offset: 0.")

        offset < byte_size(text) and
            not String.valid?(binary_part(text, offset, byte_size(text) - offset)) ->
          HTTP.error(:offset, "Offset splits a UTF-8 character; use a returned next_offset.")

        true ->
          rest = binary_part(text, offset, byte_size(text) - offset)
          shown = clip(rest, cap)
          next = offset + byte_size(shown)
          cut = next < byte_size(text)

          {:ok,
           %{
             id: key,
             url: meta["url"],
             title: meta["title"],
             fetched_at: meta["fetched_at"],
             source: meta["source"],
             sha256: meta["sha256"],
             text: shown,
             offset: offset,
             bytes: byte_size(shown),
             total_bytes: byte_size(text),
             truncated: cut,
             next_offset: if(cut, do: next, else: nil),
             notice:
               if(cut,
                 do: "More content: read(#{inspect(key)}, offset: #{next}, max_bytes: #{cap}).",
                 else: nil
               )
           }}
      end
    end
  end

  def lookup(url, mode, opts) do
    ttl = Keyword.get(opts, :cache_ttl, 3600)
    now = System.system_time(:second)

    root(opts)
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.find_value(fn path ->
      with {:ok, raw} <- File.read(path),
           {:ok, meta} <- Jason.decode(raw),
           true <- meta["url"] == url and meta["mode"] == to_string(mode),
           true <- now - meta["stored_at"] < ttl,
           true <- File.exists?(Path.join(root(opts), meta["id"] <> ".txt")) do
        meta["id"]
      else
        _ -> nil
      end
    end)
  end

  defp prune(opts, keep) do
    maximum = Keyword.get(opts, :cache_entries, 100)

    if is_integer(maximum) and maximum > 0 do
      Path.wildcard(Path.join(root(opts), "*.json"))
      |> Enum.reject(&(Path.basename(&1, ".json") == keep))
      |> Enum.sort_by(
        fn path ->
          case File.stat(path, time: :posix) do
            {:ok, stat} -> stat.mtime
            _ -> 0
          end
        end,
        :desc
      )
      |> Enum.drop(maximum - 1)
      |> Enum.each(fn path ->
        File.rm(path)
        File.rm(Path.rootname(path) <> ".txt")
      end)
    end
  end

  def clip(text, cap) when byte_size(text) <= cap, do: text

  def clip(text, cap) do
    prefix = binary_part(text, 0, cap)
    valid_prefix(prefix)
  end

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end

  def page_options(offset, cap) do
    if is_integer(offset) and offset >= 0 and is_integer(cap) and cap >= 4 and cap <= 40_000,
      do: :ok,
      else:
        HTTP.error(
          :invalid_options,
          "offset must be a nonnegative byte offset; max_bytes must be 4..40000."
        )
  end

  def options(opts) do
    valid =
      is_binary(root(opts)) and root(opts) != "" and
        is_integer(Keyword.get(opts, :cache_entries, 100)) and
        Keyword.get(opts, :cache_entries, 100) > 0 and
        is_integer(Keyword.get(opts, :cache_ttl, 3600)) and
        Keyword.get(opts, :cache_ttl, 3600) >= 0 and
        is_integer(Keyword.get(opts, :max_download_bytes, 2_000_000)) and
        Keyword.get(opts, :max_download_bytes, 2_000_000) > 0

    if valid do
      page_options(Keyword.get(opts, :offset, 0), Keyword.get(opts, :max_bytes, 12_000))
    else
      HTTP.error(
        :invalid_options,
        "Use a nonempty cache_dir path and positive cache_entries/max_download_bytes; cache_ttl may be zero."
      )
    end
  end

  defp valid_id(key) do
    if is_binary(key) and Regex.match?(~r/\A[0-9a-f]{64}\z/, key),
      do: :ok,
      else: HTTP.error(:invalid_id, "Pass the 64-character content id returned by fetch/search.")
  end
end
