defmodule Seedling.Web.Transport do
  @moduledoc false

  def url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, %{kind: :invalid_url, hint: "Use an absolute http(s) URL without credentials"}}
    end
  end

  def url(_), do: {:error, %{kind: :invalid_url}}

  # Hard wall clock deadline, not just an idle socket timeout; no implicit retries.
  # Neither request structs nor exception messages (which may contain keys) escape.
  def request(method, url, body, opts \\ []) do
    with :ok <- url(url) do
      timeout = Keyword.get(opts, :timeout, 20000)
      task = Task.async(fn -> perform(method, url, body, opts, timeout) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, %{kind: :timeout, timeout_ms: timeout}}
      end
    end
  end

  defp perform(method, url, body, opts, timeout) do
    cap = Keyword.get(opts, :max_download_bytes, 2_000_000)

    into = fn {:data, chunk}, {req, resp} ->
      if byte_size(resp.body) + byte_size(chunk) > cap, do: throw(:response_too_large)
      {:cont, {req, %{resp | body: resp.body <> chunk}}}
    end

    options = [
      method: method,
      url: url,
      into: into,
      decode_body: false,
      compressed: false,
      retry: false,
      redirect: Keyword.get(opts, :redirect, true),
      max_redirects: 5,
      receive_timeout: timeout,
      connect_options: [timeout: min(timeout, 5000)],
      headers:
        [{"user-agent", "SeedlingWeb/1.0"}, {"accept-encoding", "identity"}] ++
          Keyword.get(opts, :headers, [])
    ]

    options = if body == nil, do: options, else: Keyword.put(options, :json, body)

    case Req.request(options) do
      {:ok, resp} -> {:ok, %{status: resp.status, headers: resp.headers, body: resp.body}}
      {:error, _} -> {:error, %{kind: :network}}
    end
  rescue
    _ -> {:error, %{kind: :transport}}
  catch
    :response_too_large ->
      {:error,
       %{kind: :response_too_large, max_bytes: Keyword.get(opts, :max_download_bytes, 2_000_000)}}
  end
end
