defmodule Vega.Web do
  @moduledoc """
  HTTP-first readable web content with persistent bounded paging.
  `fetch(url)` returns `{:ok, %{id: ..., text: ..., next: ...}}`; `read(id, offset: next)`
  continues without network. `fetch(url, javascript: true)` forces Lightpanda;
  `javascript: :auto` (default) falls back on very short HTML shells.
  See docs/vega-web-search.md for limits and security boundaries.
  """
  alias Vega.Web.Cache
  def read(id, opts \\ []), do: Cache.read(id, opts)

  def fetch(url, opts \\ []) do
    bounded(fn -> do_fetch(url, opts) end, min(Keyword.get(opts, :timeout, 15000), 25000))
  end

  defp do_fetch(url, opts) do
    with :ok <- validate_url(url) do
      id = Cache.id(url)

      case if(Keyword.get(opts, :refresh, false),
             do: {:error, :refresh},
             else: Cache.read(id, opts)
           ) do
        {:ok, page} -> {:ok, Map.put(page, :cached, true)}
        _ -> fetch_new(url, opts)
      end
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  def validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  defp fetch_new(url, opts) do
    js = Keyword.get(opts, :javascript, :auto)

    result =
      if js == true do
        render(url, opts)
      else
        case http(url, opts) do
          {:ok, %{text: text, html: true} = rec} when js == :auto ->
            if String.length(text) < 160,
              do: render(url, opts),
              else: {:ok, Map.put(rec, :method, "http")}

          {:ok, rec} ->
            {:ok, Map.put(rec, :method, "http")}

          error ->
            error
        end
      end

    with {:ok, rec} <- result,
         {:ok, id} <- Cache.put(url, rec.text, Map.merge(rec, %{url: url}), opts),
         {:ok, page} <- read(id, opts) do
      {:ok, Map.put(page, :cached, false)}
    end
  end

  @doc "Bounded HTTP response, usable by other Vega web capabilities. Does not expose transport exceptions."
  def request(method, url, opts \\ []) do
    bounded(
      fn -> do_request(method, url, opts) end,
      min(Keyword.get(opts, :timeout, 15000), 25000)
    )
  end

  defp do_request(method, url, opts) do
    max = Keyword.get(opts, :max_bytes, 2_000_000)
    timeout = min(Keyword.get(opts, :timeout, 15000), 25000)

    args =
      [
        method: method,
        url: url,
        retry: false,
        receive_timeout: timeout,
        connect_options: [timeout: min(timeout, 5000)],
        decode_body: false,
        into: fn {:data, chunk}, {req, resp} ->
          body = (resp.body || "") <> chunk

          if byte_size(body) > max do
            {:halt, {req, %{resp | body: :too_large}}}
          else
            {:cont, {req, %{resp | body: body}}}
          end
        end
      ] ++ Keyword.take(opts, [:headers, :json, :redirect, :max_redirects])

    case Req.request(args) do
      {:ok, %{body: :too_large}} -> {:error, :response_too_large}
      {:ok, resp} -> {:ok, resp}
      {:error, _} -> {:error, :transport_error}
    end
  rescue
    _ -> {:error, :transport_error}
  end

  defp bounded(fun, timeout) do
    parent = self()
    tag = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        if leader = Process.whereis(:user), do: Process.group_leader(self(), leader)

        result =
          try do
            fun.()
          rescue
            _ -> {:error, :web_operation_failed}
          catch
            _, _ -> {:error, :web_operation_failed}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^pid, _} ->
        {:error, :web_operation_failed}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mon, :process, ^pid, _} -> :ok
        after
          1000 -> Process.demonitor(mon, [:flush])
        end

        {:error, :timeout}
    end
  end

  defp http(url, opts) do
    with {:ok, resp} <- request(:get, url, opts) do
      cond do
        resp.status not in 200..299 ->
          {:error, {:http_status, resp.status}}

        not is_binary(resp.body) or not String.valid?(resp.body) ->
          {:error, :unsupported_encoding}

        true ->
          type = Req.Response.get_header(resp, "content-type") |> Enum.join(";")

          cond do
            String.contains?(type, "html") ->
              {:ok, %{text: extract(resp.body), html: true, title: title(resp.body)}}

            String.contains?(type, ["text/", "json", "xml"]) ->
              {:ok, %{text: resp.body, html: false}}

            true ->
              {:error, {:unsupported_content_type, String.slice(type, 0, 120)}}
          end
      end
    end
  end

  @doc "Conservative HTML-to-readable-text extraction (not a full DOM/Readability parser)."
  def extract(html) do
    html =
      Regex.replace(
        ~r/<(script|style|noscript|svg|nav|footer|header)\b[^>]*>.*?<\/\1\s*>/is,
        html,
        ""
      )

    main =
      case Regex.run(~r/<(?:main|article)\b[^>]*>(.*?)<\/(?:main|article)\s*>/is, html) do
        [_, body] -> body
        _ -> html
      end

    main
    |> then(
      &Regex.replace(
        ~r/<a\b[^>]*href=["'](https?:\/\/[^"']+)["'][^>]*>(.*?)<\/a>/is,
        &1,
        "\\2 (\\1)"
      )
    )
    |> then(&Regex.replace(~r/<(?:br|\/p|\/div|\/li|\/h[1-6]|\/section|\/tr)\b[^>]*>/i, &1, "\n"))
    |> then(&Regex.replace(~r/<[^>]*>/s, &1, ""))
    |> entities()
    |> then(&Regex.replace(~r/[\t\r ]+/, &1, " "))
    |> then(&Regex.replace(~r/\n\s*\n\s*\n/, &1, "\n\n"))
    |> String.trim()
  end

  defp title(html) do
    case Regex.run(~r/<title\b[^>]*>(.*?)<\/title>/is, html) do
      [_, text] -> extract(text) |> String.slice(0, 300)
      _ -> nil
    end
  end

  defp entities(text) do
    text =
      Enum.reduce(
        [
          {"&nbsp;", " "},
          {"&amp;", "&"},
          {"&lt;", "<"},
          {"&gt;", ">"},
          {"&quot;", "\""},
          {"&#39;", "'"}
        ],
        text,
        fn {a, b}, t -> String.replace(t, a, b) end
      )

    Regex.replace(~r/&#(x[0-9a-fA-F]+|[0-9]+);/, text, fn full, code ->
      try do
        n =
          if String.starts_with?(code, "x"),
            do: String.to_integer(String.slice(code, 1..-1//1), 16),
            else: String.to_integer(code)

        <<n::utf8>>
      rescue
        _ -> full
      end
    end)
  end

  defp read_browser_output(path, max) do
    with {:ok, stat} <- File.stat(path) do
      if stat.size <= max, do: File.read(path), else: {:error, :response_too_large}
    end
  end

  @doc "Fetch JavaScript-rendered Markdown with Lightpanda. Uses shared bounded shell helper; no shell interpolation of URL."
  def render(url, opts \\ []) do
    with :ok <- validate_url(url) do
      binary = Keyword.get(opts, :lightpanda, "/usr/local/bin/lightpanda")

      if File.exists?(binary) do
        # POSIX shell quotes only to compose the existing shell helper, not an independent runner.
        quote = fn s -> "'" <> String.replace(s, "'", "'\\''") <> "'" end

        result =
          Vega.Files.sh(quote.(binary) <> " fetch --dump markdown " <> quote.(url),
            timeout: min(Keyword.get(opts, :timeout, 15000), 25000)
          )

        case result.status do
          0 ->
            case read_browser_output(result.path, Keyword.get(opts, :max_bytes, 2_000_000)) do
              {:ok, data} ->
                File.rm(result.path)

                if byte_size(data) <= Keyword.get(opts, :max_bytes, 2_000_000),
                  do: {:ok, %{text: data, method: "lightpanda"}},
                  else: {:error, :response_too_large}

              {:error, reason} ->
                File.rm(result.path)
                {:error, reason}
            end

          124 ->
            File.rm(result.path)
            {:error, :browser_timeout}

          _ ->
            File.rm(result.path)
            {:error, :browser_failed}
        end
      else
        {:error, :lightpanda_missing}
      end
    end
  rescue
    _ -> {:error, :browser_failed}
  end
end
