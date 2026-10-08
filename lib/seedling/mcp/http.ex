defmodule Seedling.MCP.HTTP do
  @moduledoc false
  def start(owner, token, config, method, body, headers) do
    :erlang.spawn_opt(
      fn ->
        into = fn {:data, data}, {req, resp} ->
          unless Process.get(:headers_sent) do
            send(owner, {:http_headers, token, resp.status, resp.headers})
            Process.put(:headers_sent, true)
          end

          send(owner, {:http_data, token, data})
          {:cont, {req, resp}}
        end

        result =
          Req.request(
            url: config["url"],
            method: method,
            body: body,
            headers: headers,
            into: into,
            retry: false,
            redirect: false,
            receive_timeout: config["http_idle_timeout_ms"] || 120_000,
            connect_options: [timeout: config["connect_timeout_ms"] || 5000]
          )

        case result do
          {:ok, resp} ->
            unless Process.get(:headers_sent),
              do: send(owner, {:http_headers, token, resp.status, resp.headers})

            send(owner, {:http_done, token, :ok})

          {:error, reason} ->
            send(owner, {:http_done, token, {:error, Exception.message(reason)}})
        end
      end,
      [:link, :monitor]
    )
  end

  def header_value(value) do
    if (String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")) or
         String.trim(value) != value or
         Enum.any?(:binary.bin_to_list(value), &(&1 < 32 or &1 > 126)) do
      "=?base64?" <> Base.encode64(value) <> "?="
    else
      value
    end
  end
end
