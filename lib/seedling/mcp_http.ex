defmodule Seedling.MCP.HTTP do
  @moduledoc "Streamable HTTP transport: JSON/SSE POST, session headers and server GET event stream. Static headers only; no OAuth/legacy HTTP+SSE."
  use GenServer
  def start(owner, server), do: GenServer.start(__MODULE__, {owner, server})
  def command(pid, json), do: GenServer.cast(pid, {:send, json})
  def cancel(pid, id), do: GenServer.cast(pid, {:cancel, id})
  def version(pid, version), do: GenServer.cast(pid, {:version, version})
  def tools(pid, tools), do: GenServer.cast(pid, {:tools, tools})

  def init({owner, server}) do
    Process.monitor(owner)

    {:ok,
     %{
       owner: owner,
       server: server,
       session: nil,
       workers: %{},
       requests: %{},
       tools: %{},
       version: "2025-11-25",
       stream: nil
     }}
  end

  def handle_cast({:version, version}, s), do: {:noreply, %{s | version: version}}

  def handle_cast({:tools, tools}, s) do
    bindings =
      Map.new(tools, fn tool ->
        {:ok, entries} = Seedling.MCP.Headers.bindings(tool)
        {tool["name"], entries}
      end)

    {:noreply, %{s | tools: Map.merge(s.tools, bindings)}}
  end

  def handle_cast({:cancel, id}, s) do
    case Map.pop(s.requests, id) do
      {nil, _} ->
        {:noreply, s}

      {pid, requests} ->
        Process.exit(pid, :kill)
        {:noreply, %{s | requests: requests, workers: Map.delete(s.workers, pid)}}
    end
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
    if Map.has_key?(s.workers, worker) do
      case result do
        {:ok, %{status: status}} when status in [200, 202, 204, 400, 404, 405] -> :ok
        error -> send(s.owner, {self(), {:exit_status, {:http, inspect(error, limit: 5)}}})
      end

      case Enum.find(s.requests, fn {_id, pid} -> pid == worker end) do
        {id, _} -> send(s.owner, {self(), {:stream_closed, id}})
        _ -> :ok
      end
    end

    if worker == s.stream and not match?({:ok, %{status: 405}}, result),
      do: Process.send_after(self(), :stream, 1000)

    {:noreply,
     %{
       s
       | workers: Map.delete(s.workers, worker),
         requests: Map.reject(s.requests, fn {_id, pid} -> pid == worker end),
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

  def terminate(_, s) do
    Enum.each(Map.keys(s.workers), &Process.exit(&1, :kill))

    if s.session do
      headers =
        Map.merge(s.server["headers"] || %{}, %{
          "mcp-session-id" => s.session,
          "mcp-protocol-version" => s.version
        })

      # Best effort legacy session cleanup; modern protocol has no session/DELETE.
      Req.request(
        url: s.server["url"],
        method: :delete,
        headers: headers,
        retry: false,
        redirect: false,
        receive_timeout: 1000,
        connect_options: [timeout: 1000]
      )
    end

    :ok
  end

  defp stream(%{stream: pid} = s) when is_pid(pid), do: s

  defp stream(s) do
    before = Map.keys(s.workers)
    s = worker(s, :get, nil)
    %{s | stream: hd(Map.keys(s.workers) -- before)}
  end

  defp header_value(value), do: Seedling.MCP.Headers.encode(value)

  defp worker(s, method, body) do
    transport = self()

    msg = if body, do: Jason.decode!(body), else: %{}

    version =
      get_in(msg, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) || s.version

    headers =
      Map.merge(s.server["headers"] || %{}, %{
        "accept" => "application/json, text/event-stream",
        "mcp-protocol-version" => version
      })

    headers =
      if not is_nil(s.session) and version != "2026-07-28",
        do: Map.put(headers, "mcp-session-id", s.session),
        else: headers

    headers = if msg["method"], do: Map.put(headers, "mcp-method", msg["method"]), else: headers

    headers =
      if msg["method"] in ["tools/call", "prompts/get", "resources/read"] do
        value = get_in(msg, ["params", "name"]) || get_in(msg, ["params", "uri"])
        Map.put(headers, "mcp-name", header_value(value))
      else
        headers
      end

    headers =
      if msg["method"] == "tools/call" and version == "2026-07-28",
        do:
          Map.merge(
            headers,
            Seedling.MCP.Headers.headers(
              Map.get(s.tools, get_in(msg, ["params", "name"]), []),
              get_in(msg, ["params", "arguments"]) || %{}
            )
          ),
        else: headers

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

              if text != "" and match?({:ok, %{"jsonrpc" => "2.0"}}, Jason.decode(text)) do
                send(transport, {:bytes, self(), text <> "\n"})
              else
                if msg["method"] == "server/discover" and resp.status in [400, 404, 405],
                  do:
                    send(
                      transport,
                      {:bytes, self(),
                       Jason.encode!(%{
                         "jsonrpc" => "2.0",
                         "id" => msg["id"],
                         "error" => %{"code" => -32601, "message" => "Legacy endpoint"}
                       }) <> "\n"}
                    )
              end
            end

          _ ->
            :ok
        end

        send(transport, {:done, self(), result})
      end)

    requests =
      if msg["method"] == "subscriptions/listen",
        do: Map.put(s.requests, msg["id"], pid),
        else: s.requests

    %{s | workers: Map.put(s.workers, pid, ref), requests: requests}
  end
end
