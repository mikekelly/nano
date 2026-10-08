defmodule Seedling.Web.HTTP do
  @moduledoc false

  def request(method, url, headers, body, opts) do
    timeout = Keyword.get(opts, :timeout, 20_000)
    cap = Keyword.get(opts, :max_download_bytes, 2_000_000)

    if is_integer(timeout) and timeout > 0 and is_integer(cap) and cap > 0 do
      caller = self()
      ref = make_ref()

      {pid, mon} =
        spawn_monitor(fn ->
          result = safe_request(method, url, headers, body, opts, cap, timeout)
          send(caller, {ref, result})
        end)

      receive do
        {^ref, result} ->
          Process.demonitor(mon, [:flush])
          result

        {:DOWN, ^mon, :process, ^pid, _} ->
          error(:transport, "HTTP worker failed; retry the request.")
      after
        timeout ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^mon, :process, ^pid, _} -> :ok
          end

          receive do
            {^ref, _} -> :ok
          after
            0 -> :ok
          end

          error(:timeout, "HTTP deadline exceeded; increase :timeout or retry.")
      end
    else
      error(:invalid_options, "timeout and max_download_bytes must be positive integers.")
    end
  end

  defp safe_request(method, url, headers, body, opts, cap, timeout) do
    try do
      result =
        case opts[:transport] do
          fun when is_function(fun, 5) -> fun.(method, url, headers, body, opts)
          nil -> real_request(method, url, headers, body, opts, cap, timeout)
          _ -> error(:invalid_options, "transport must be a five-argument function.")
        end

      case result do
        {:ok, %{body: data} = response} when is_binary(data) ->
          if byte_size(data) > cap or Map.get(response, :over_limit, false),
            do:
              error(
                :download_limit,
                "Response exceeds max_download_bytes; increase it explicitly."
              ),
            else: {:ok, response}

        {:error, %{reason: _} = issue} ->
          {:error, issue}

        {:error, _} ->
          error(:transport, "Network request failed; check connectivity and retry.")

        _ ->
          error(:transport, "Invalid HTTP response; transport must return a binary body.")
      end
    rescue
      _ -> error(:transport, "HTTP request failed; check options and connectivity.")
    catch
      _, _ -> error(:transport, "HTTP request failed; retry.")
    end
  end

  defp real_request(method, url, headers, body, opts, cap, timeout) do
    into = fn {:data, chunk}, {req, resp} ->
      current = resp.body || ""

      if byte_size(current) + byte_size(chunk) > cap do
        {:halt, {req, Req.Response.put_private(resp, :over_limit, true)}}
      else
        {:cont, {req, %{resp | body: current <> chunk}}}
      end
    end

    request_opts = [
      method: method,
      url: url,
      headers: headers,
      body: body,
      into: into,
      decode_body: false,
      retry: false,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      max_redirects: 5,
      redirect: Keyword.get(opts, :redirect, true)
    ]

    case Req.request(request_opts) do
      {:ok, resp} ->
        {:ok,
         %{
           status: resp.status,
           body: resp.body || "",
           headers: resp.headers,
           over_limit: resp.private[:over_limit] || false
         }}

      {:error, _} ->
        error(:transport, "Network request failed; check connectivity and retry.")
    end
  end

  def header(%{headers: headers}, name) when is_map(headers) do
    case Map.get(headers, name, []) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def header(_, _), do: nil

  def error(reason, message), do: {:error, %{reason: reason, message: message}}
end
