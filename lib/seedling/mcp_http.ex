defmodule Seedling.MCP.HTTP do
  @moduledoc "Streamable HTTP transport: JSON/SSE POST, session headers and server GET event stream. Static headers only; no OAuth/legacy HTTP+SSE."
  use GenServer
  def start(owner, server), do: GenServer.start(__MODULE__, {owner, server})
  def command(pid, json), do: GenServer.cast(pid, {:send, json})

  def init({owner, server}) do
    Process.monitor(owner)
    {:ok, %{owner: owner, server: server, session: nil, workers: %{}, stream: nil}}
  end

  def handle_cast({:send, json}, s) do
    msg = Jason.decode!(json)
    s = worker(s, :post, json)
    s = if msg["method"] == "notifications/initialized", do: stream(s), else: s
    {:noreply, s}
  end

  def handle_info({:session, worker, session}, s) do
    if Map.has_key?(s.workers, worker),
      do: {:noreply, %{s | session: session}},
      else: {:noreply, s}
  end

  def handle_info({:bytes, worker, bytes}, s) do
    if Map.has_key?(s.workers, worker), do: send(s.owner, {self(), {:data, bytes}})
    {:noreply, s}
  end

  def handle_info({:done, worker, result}, s) do
    case result do
      {:ok, %{status: status}} when status in [200, 202, 204, 405] -> :ok
      error -> send(s.owner, {self(), {:exit_status, {:http, inspect(error, limit: 5)}}})
    end

    if worker == s.stream and not match?({:ok, %{status: 405}}, result),
      do: Process.send_after(self(), :stream, 1000)

    {:noreply,
     %{
       s
       | workers: Map.delete(s.workers, worker),
         stream: if(worker == s.stream, do: nil, else: s.stream)
     }}
  end

  def handle_info(:stream, s), do: {:noreply, stream(s)}
  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = s), do: {:stop, :normal, s}

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    if Map.get(s.workers, pid) == ref and reason != :normal,
      do: send(s.owner, {self(), {:exit_status, {:worker, reason}}})

    {:noreply, %{s | workers: Map.delete(s.workers, pid)}}
  end

  def terminate(_, s), do: Enum.each(Map.keys(s.workers), &Process.exit(&1, :kill))
  defp stream(%{stream: pid} = s) when is_pid(pid), do: s

  defp stream(s) do
    before = Map.keys(s.workers)
    s = worker(s, :get, nil)
    %{s | stream: hd(Map.keys(s.workers) -- before)}
  end

  defp worker(s, method, body) do
    transport = self()

    headers =
      Map.merge(s.server["headers"] || %{}, %{
        "accept" => "application/json, text/event-stream",
        "mcp-protocol-version" => "2025-11-25"
      })

    headers = if s.session, do: Map.put(headers, "mcp-session-id", s.session), else: headers

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:mcp_buffer, "")

        opts = [
          url: s.server["url"],
          method: method,
          headers: headers,
          retry: false,
          redirect: false,
          receive_timeout: 300_000,
          into: fn {:data, data}, {req, resp} ->
            case Req.Response.get_header(resp, "mcp-session-id") do
              [session | _] -> send(transport, {:session, self(), session})
              _ -> :ok
            end

            buffer = Process.get(:mcp_buffer) <> data
            if byte_size(buffer) > 16_000_000, do: raise("HTTP frame too large")

            if Enum.any?(
                 Req.Response.get_header(resp, "content-type"),
                 &String.contains?(&1, "text/event-stream")
               ) do
              normalized = String.replace(buffer, "\r\n", "\n")
              parts = String.split(normalized, "\n\n")
              {frames, [rest]} = Enum.split(parts, -1)

              Enum.each(frames, fn frame ->
                text =
                  frame
                  |> String.split("\n")
                  |> Enum.filter(&String.starts_with?(&1, "data:"))
                  |> Enum.map(
                    &(&1
                      |> String.replace_prefix("data:", "")
                      |> String.trim_leading(" "))
                  )
                  |> Enum.join("\n")

                if text != "", do: send(transport, {:bytes, self(), text <> "\n"})
              end)

              Process.put(:mcp_buffer, rest)
            else
              Process.put(:mcp_buffer, buffer)
            end

            {:cont, {req, resp}}
          end
        ]

        opts =
          if body,
            do:
              Keyword.put(opts, :body, body)
              |> Keyword.update!(:headers, &Map.put(&1, "content-type", "application/json")),
            else: opts

        result = Req.request(opts)

        case result do
          {:ok, resp} ->
            case Req.Response.get_header(resp, "mcp-session-id") do
              [session | _] -> send(transport, {:session, self(), session})
              _ -> :ok
            end

            unless Enum.any?(
                     Req.Response.get_header(resp, "content-type"),
                     &String.contains?(&1, "text/event-stream")
                   ) do
              text = Process.get(:mcp_buffer)

              if text != "" and resp.status == 200,
                do: send(transport, {:bytes, self(), text <> "\n"})
            end

          _ ->
            :ok
        end

        send(transport, {:done, self(), result})
      end)

    %{s | workers: Map.put(s.workers, pid, ref)}
  end
end
