defmodule Nano.Web do
  @moduledoc "HTTP-first readable pages. fetch/2 caches; read/2 pages by id. See docs/nova-web.md."
  def fetch(url, opts \\ []) do
    with :ok <- valid_url(url) do
      id = hash(url <> if(opts[:browser], do: ":browser", else: ""))

      case load(id, opts) do
        {:ok, p} ->
          if opts[:refresh] != true and
               System.system_time(:second) - p["fetched_at"] < Keyword.get(opts, :ttl, 3600),
             do: slice(p, opts),
             else: download(url, id, opts)

        _ ->
          download(url, id, opts)
      end
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  def valid_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> :ok
      _ -> {:error, :invalid_url}
    end
  end

  def valid_url(_), do: {:error, :invalid_url}

  def read(id, opts \\ []) do
    if is_binary(id) and Regex.match?(~r/\A[a-f0-9]{64}\z/, id) do
      with {:ok, p} <- load(id, opts), do: slice(p, opts)
    else
      {:error, :invalid_id}
    end
  end

  def store(url, text, opts \\ []) do
    id = Keyword.get(opts, :id, hash(url <> text))

    p = %{
      "id" => id,
      "url" => url,
      "title" => Keyword.get(opts, :title, url),
      "text" => text,
      "fetched_at" => System.system_time(:second)
    }

    file = path(id, opts)

    with true <- Regex.match?(~r/\A[a-f0-9]{64}\z/, id),
         true <- byte_size(text) <= Keyword.get(opts, :max_download_bytes, 5_000_000),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- atomic_write(file, Jason.encode!(p)) do
      prune(Path.dirname(file), Keyword.get(opts, :cache_entries, 100))
      slice(p, opts)
    else
      false -> {:error, :invalid_or_oversized_page}
      error -> error
    end
  rescue
    _ -> {:error, :storage_failed}
  end

  defp download(url, id, opts) do
    result =
      if opts[:browser] do
        Nano.Lightpanda.fetch(url, opts)
      else
        request =
          [
            url: url,
            decode_body: false,
            compressed: false,
            into: bounded_sink(Keyword.get(opts, :max_download_bytes, 5_000_000)),
            receive_timeout: Keyword.get(opts, :timeout, 20_000),
            connect_options: [timeout: 5000],
            retry: false
          ] ++ Keyword.get(opts, :req_options, [])

        case Req.get(request) do
          {:ok, %{private: %{nano_too_large: true}}} ->
            {:error, :page_too_large}

          {:ok, %{status: s, body: body, headers: headers}}
          when s in 200..299 and is_binary(body) ->
            type = headers |> Map.get("content-type", []) |> Enum.join(";")

            cond do
              byte_size(body) > Keyword.get(opts, :max_download_bytes, 5_000_000) ->
                {:error, :page_too_large}

              String.contains?(type, "pdf") ->
                {:error, :pdf_not_supported}

              String.contains?(type, "html") ->
                {:ok, extract(body)}

              String.contains?(type, "text/") or type == "" ->
                {:ok, body}

              true ->
                {:error, {:unsupported_content_type, type}}
            end

          {:ok, %{status: s}} ->
            {:error, {:http_status, s}}

          {:error, _} ->
            {:error, :network_error}

          _ ->
            {:error, :invalid_response}
        end
      end

    with {:ok, text} <- result, do: store(url, text, Keyword.put(opts, :id, id))
  end

  @doc "Lightweight extraction, not full Mozilla Readability."
  def extract(html) do
    html
    |> String.replace(~r/<(script|style|nav|footer|header)\b[^>]*>.*?<\/\1>/is, "")
    |> String.replace(~r/<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is, "\\2 (\\1)")
    |> String.replace(~r/<\/?(?:p|div|h[1-6]|li|br|section|article|pre|tr)\b[^>]*>/i, "\n")
    |> String.replace(~r/<[^>]*>/s, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/[\t ]+/, " ")
    |> String.replace(~r/\n\s*\n+/, "\n\n")
    |> String.trim()
  end

  defp slice(p, opts) do
    lines = String.split(p["text"], "\n")
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, 100)
    cap = Keyword.get(opts, :max_bytes, 12_000)

    cond do
      not is_integer(offset) or offset < 1 or offset > length(lines) ->
        {:error, {:invalid_offset, length(lines)}}

      not is_integer(limit) or limit < 1 or not is_integer(cap) or cap < 1 ->
        {:error, :invalid_slice}

      true ->
        selected = Enum.slice(lines, offset - 1, min(limit, 2000))

        {taken, _} =
          Enum.reduce_while(selected, {[], 0}, fn line, {acc, bytes} ->
            n = byte_size(line) + 16

            if bytes + n > min(cap, 30_000),
              do: {:halt, {acc, bytes}},
              else: {:cont, {[line | acc], bytes + n}}
          end)

        if taken == [],
          do: {:error, {:line_too_large, offset, byte_size(hd(selected))}},
          else: page_result(p, lines, taken, offset)
    end
  end

  defp page_result(p, lines, taken, offset) do
    next = if offset + length(taken) <= length(lines), do: offset + length(taken), else: nil

    {:ok,
     %{
       id: p["id"],
       url: p["url"],
       title: p["title"],
       fetched_at: p["fetched_at"],
       text:
         taken
         |> Enum.reverse()
         |> Enum.with_index(offset)
         |> Enum.map_join("\n", fn {line, n} -> "#{n}: #{line}" end),
       offset: offset,
       next_offset: next,
       total_lines: length(lines),
       truncated: next != nil
     }}
  end

  defp bounded_sink(cap) do
    fn {:data, data}, {req, resp} ->
      if byte_size(resp.body) + byte_size(data) > cap do
        {:halt, {req, %{resp | private: Map.put(resp.private, :nano_too_large, true)}}}
      else
        {:cont, {req, %{resp | body: resp.body <> data}}}
      end
    end
  end

  defp atomic_write(file, data) do
    temp =
      file <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".tmp"

    result = with :ok <- File.write(temp, data, [:exclusive]), do: File.rename(temp, file)
    File.rm(temp)
    result
  end

  defp prune(dir, count) do
    Path.wildcard(Path.join(dir, "*.json"))
    |> Enum.sort_by(
      fn file ->
        case File.stat(file) do
          {:ok, s} -> s.mtime
          _ -> 0
        end
      end,
      :desc
    )
    |> Enum.drop(max(count, 1))
    |> Enum.each(&File.rm/1)
  end

  defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  defp path(id, opts),
    do:
      Path.join(
        Keyword.get(opts, :cache_dir, Path.join(System.tmp_dir!(), "nano-web-cache")),
        id <> ".json"
      )

  defp load(id, opts) do
    with {:ok, data} <- File.read(path(id, opts)), {:ok, p} <- Jason.decode(data), do: {:ok, p}
  end
end
