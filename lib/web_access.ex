defmodule WebAccess do
  @moduledoc """
  HTTP-first readable web pages, bounded disk cache and verifiable quotations.

      {:ok, page} = WebAccess.fetch("https://elixir-lang.org")
      WebAccess.read(page.id, offset: page.next_offset || 0)
      WebAccess.cite(page.id, "Elixir")
      WebAccess.fetch("https://example.org", browser: true)

  All operations return values. Pages contain at most 12 KB by default (maximum 24 KB);
  offsets count UTF-8 **bytes**, and `next_offset` is safe to pass verbatim. Stored text
  is limited to 1 MB; HTTP input to 2 MB. A one-hour, 32-entry disk cache survives agent
  and node restarts; eviction means an id may cease to exist. Quotes carry URL, retrieval
  time, content SHA256 and byte location in the stored extraction. These are evidence of
  what was retrieved, not a claim that a page is truthful.

  `refresh: true` bypasses URL cache. `browser: true` uses Lightpanda for JavaScript;
  short HTTP pages include a hint but never silently launch a browser. HTML extraction
  is a heuristic (main/article, headings, links, removal of scripts/chrome), not a DOM
  or Readability implementation. Check important quotations against their source.
  PDF, media and repository checkout are unsupported; GitHub HTML/raw text work as pages.
  No authentication/cookie support. URLs may access local hosts: this is an agent tool,
  not a safe public proxy for untrusted callers.

  Options: `bytes:`, `offset:`, `timeout:` (default 15000, maximum 25000), `cache_dir:`
  (default `/data/web-access`), `title:` for store. `request_options:` allows Req test
  adapters or proxy configuration but cannot override enforced size/time limits.
  `WebAccess.Browser` documents CDP service and browser-specific options.
  """
  @max_text 1_000_000
  @max_input 2_000_000
  @ttl 3600
  @entries 32

  def fetch(url, opts \\ []) do
    protect(fn ->
      with :ok <- validate_url(url), :ok <- validate_page_opts(opts) do
        mode = if opts[:browser], do: "browser", else: "http"

        case if(opts[:refresh], do: nil, else: cached(url, mode, opts)) do
          nil -> fetch_new(url, mode, opts)
          record -> page(record, opts, true)
        end
      end
    end)
  end

  @doc "Stores already-readable content, then returns its first bounded page."
  def store(url, text, opts \\ []) do
    protect(fn ->
      with :ok <- validate_url(url),
           :ok <- validate_page_opts(opts),
           true <- is_binary(text) and String.valid?(text) do
        truncated = byte_size(text) > @max_text
        text = cut(text, @max_text)

        record = %{
          "id" => hash(url <> "\n" <> (opts[:mode] || "stored") <> "\n" <> text),
          "url" => url,
          "request_url" => opts[:request_url] || url,
          "title" => cut(to_string(opts[:title] || url), 500),
          "text" => text,
          "sha256" => hash(text),
          "fetched_at" => System.system_time(:second),
          "mode" => opts[:mode] || "stored",
          "source_truncated" => opts[:source_truncated] || truncated
        }

        with :ok <- save(record, opts), do: page(record, opts, false)
      else
        false -> {:error, :invalid_utf8_text}
        error -> error
      end
    end)
  end

  @doc "Reads cached extraction; offset is a byte offset, not a line/character index."
  def read(id, opts \\ []) do
    protect(fn ->
      with :ok <- validate_page_opts(opts),
           {:ok, record} <- load(id, opts),
           do: page(record, opts, true)
    end)
  end

  @doc "Finds an exact quotation (1..4000 bytes); returns its first byte range and digest."
  def cite(id, quote, opts \\ []) do
    protect(fn ->
      with true <- is_binary(quote) and byte_size(quote) in 1..4000,
           {:ok, record} <- load(id, opts) do
        case :binary.match(record["text"], quote) do
          :nomatch ->
            {:error, :quote_not_found}

          {offset, size} ->
            {:ok,
             %{
               id: id,
               url: record["url"],
               title: record["title"],
               fetched_at: record["fetched_at"],
               sha256: record["sha256"],
               quote: quote,
               offset: offset,
               end_offset: offset + size
             }}
        end
      else
        false -> {:error, :quote_must_be_1_to_4000_bytes}
        error -> error
      end
    end)
  end

  @doc false
  def validate_url(url) when is_binary(url) and byte_size(url) <= 4096 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if String.match?(url, ~r/[\x00-\x20\x7f]/), do: {:error, :invalid_url}, else: :ok

      _ ->
        {:error, :http_https_url_without_credentials_required}
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  defp fetch_new(url, "browser", opts) do
    with {:ok, result} <- WebAccess.Browser.render(url, opts) do
      store(
        result.url,
        result.text,
        Keyword.merge(opts,
          title: result.title,
          mode: "browser",
          source_truncated: result.truncated
        )
      )
    end
  end

  defp fetch_new(url, "http", opts) do
    timeout = opts[:timeout] || 15_000

    if not is_integer(timeout) or timeout not in 1..25_000 do
      {:error, :timeout_must_be_1_to_25000_ms}
    else
      task = Task.async(fn -> protect(fn -> http(url, timeout, opts) end) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} ->
          store(
            result.url,
            result.text,
            Keyword.merge(opts, title: result.title, mode: "http", request_url: url)
          )

        {:ok, error} ->
          error

        nil ->
          {:error, :timeout}

        {:exit, _} ->
          {:error, :fetch_worker_failed}
      end
    end
  end

  defp http(url, timeout, opts) do
    stream = fn {:data, data}, {req, resp} ->
      if byte_size(resp.body) + byte_size(data) > @max_input do
        {:halt, {req, %{resp | private: Map.put(resp.private, :web_too_large, true)}}}
      else
        {:cont,
         {req,
          %{
            resp
            | body: resp.body <> data,
              private: Map.put(resp.private, :web_final_url, URI.to_string(req.url))
          }}}
      end
    end

    options =
      Keyword.merge(opts[:request_options] || [],
        url: url,
        into: stream,
        retry: false,
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        max_redirects: 5,
        decode_body: false,
        raw: true,
        compressed: false,
        headers: [
          {"user-agent", "Nano-WebAccess/1.0"},
          {"accept", "text/html,text/plain,text/markdown"}
        ]
      )

    case Req.get(options) do
      {:ok, %{private: %{web_too_large: true}}} ->
        {:error, {:response_too_large, @max_input}}

      {:ok, %{status: status}} when status not in 200..299 ->
        {:error, {:http_status, status}}

      {:ok, response} ->
        type = Req.Response.get_header(response, "content-type") |> List.first() || ""
        final_url = response.private[:web_final_url] || url
        encoding = Req.Response.get_header(response, "content-encoding")

        cond do
          encoding not in [[], ["identity"]] ->
            {:error, :unexpected_content_encoding}

          byte_size(response.body) > @max_input ->
            {:error, {:response_too_large, @max_input}}

          not String.valid?(response.body) ->
            {:error, :invalid_utf8_response}

          String.contains?(type, "html") ->
            {:ok, Map.put(WebAccess.HTML.extract(response.body, final_url), :url, final_url)}

          String.starts_with?(type, "text/") or type == "" ->
            {:ok, %{title: final_url, url: final_url, text: response.body}}

          true ->
            {:error, {:unsupported_content_type, cut(type, 200)}}
        end

      {:error, _} ->
        {:error, :http_transport_failed}
    end
  end

  defp page(record, opts, cached?) do
    text = record["text"]
    offset = opts[:offset] || 0

    cond do
      offset > byte_size(text) ->
        {:error, {:offset_past_end, byte_size(text)}}

      not String.valid?(binary_part(text, offset, byte_size(text) - offset)) ->
        {:error, :offset_not_utf8_boundary}

      true ->
        selected =
          text |> binary_part(offset, byte_size(text) - offset) |> cut(opts[:bytes] || 12_000)

        next = offset + byte_size(selected)

        {:ok,
         %{
           id: record["id"],
           url: record["url"],
           title: record["title"],
           text: selected,
           offset: offset,
           next_offset: if(next < byte_size(text), do: next),
           bytes: byte_size(selected),
           total_bytes: byte_size(text),
           cached: cached?,
           source_truncated: record["source_truncated"],
           fetched_at: record["fetched_at"],
           sha256: record["sha256"],
           mode: record["mode"],
           hint:
             if(record["mode"] == "http" and byte_size(text) < 200,
               do: "Short HTTP extraction; if this is a JavaScript shell, retry browser: true."
             )
         }}
    end
  end

  defp validate_page_opts(opts) do
    if is_integer(opts[:bytes] || 12000) and (opts[:bytes] || 12000) in 4..24000 and
         is_integer(opts[:offset] || 0) and (opts[:offset] || 0) >= 0,
       do: :ok,
       else: {:error, :bytes_must_be_4_to_24000_and_offset_nonnegative}
  end

  defp root(opts), do: opts[:cache_dir] || "/data/web-access"

  defp load(id, opts) when is_binary(id) do
    if id =~ ~r/\A[0-9a-f]{64}\z/ do
      with {:ok, data} <- File.read(Path.join(root(opts), id <> ".json")),
           {:ok, record} <- Jason.decode(data),
           true <- record["fetched_at"] + @ttl > System.system_time(:second) do
        {:ok, record}
      else
        _ -> {:error, :cache_miss_or_expired}
      end
    else
      {:error, :invalid_id}
    end
  end

  defp load(_, _), do: {:error, :invalid_id}

  defp cached(url, mode, opts) do
    Path.wildcard(Path.join(root(opts), "*.json"))
    |> Enum.find_value(fn path ->
      case load(Path.basename(path, ".json"), opts) do
        {:ok, %{"request_url" => ^url, "mode" => ^mode} = record} -> record
        _ -> nil
      end
    end)
  end

  defp save(record, opts) do
    root = root(opts)

    :global.trans({{__MODULE__, Path.expand(root)}, self()}, fn ->
      with :ok <- File.mkdir_p(root) do
        files = Path.wildcard(Path.join(root, "*.json"))

        Enum.each(files, fn path ->
          case load(Path.basename(path, ".json"), opts) do
            {:ok, old} ->
              if old["request_url"] == record["request_url"] and old["mode"] == record["mode"],
                do: File.rm(path)

            _ ->
              File.rm(path)
          end
        end)

        survivors =
          Path.wildcard(Path.join(root, "*.json"))
          |> Enum.sort_by(&File.stat!(&1, time: :posix).mtime, :desc)

        Enum.each(Enum.drop(survivors, @entries - 1), &File.rm/1)
        path = Path.join(root, record["id"] <> ".json")
        temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
        with :ok <- File.write(temporary, Jason.encode!(record)), do: File.rename(temporary, path)
      end
    end)
  end

  defp hash(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
  defp cut(text, max) when byte_size(text) <= max, do: text
  defp cut(text, max), do: valid_prefix(binary_part(text, 0, max))

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end

  defp protect(fun) do
    try do
      fun.()
    rescue
      _ -> {:error, :web_access_failed}
    catch
      _, _ -> {:error, :web_access_failed}
    end
  end
end
