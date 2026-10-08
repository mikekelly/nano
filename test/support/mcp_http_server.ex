defmodule MCP.HTTPTestServer do
  @moduledoc """
  Port-zero HTTP/1.1 fixture controlled by the test process. Requests arrive as
  `{:http_request, connection_pid, %{method: ..., headers: ..., body: ...}}`.
  Ordinary responses close connections. SSE connections remain open so tests can
  send independent chunks and observe client cancellation.
  """
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
  def url(server), do: GenServer.call(server, :url)

  def reply(connection, status, headers \\ [], body \\ "") do
    command(connection, {:reply, status, headers, body})
  end

  def sse(connection), do: command(connection, :sse)
  def chunk(connection, data), do: command(connection, {:chunk, data})

  defp command(connection, command) do
    ref = make_ref()
    send(connection, {:command, self(), ref, command})

    receive do
      {^ref, result} -> result
    after
      2000 -> raise "fixture connection did not acknowledge #{inspect(command)}"
    end
  end

  @impl true
  def init(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    acceptor = spawn_link(fn -> accept(listener, owner) end)
    {:ok, %{listener: listener, acceptor: acceptor, port: port}}
  end

  @impl true
  def handle_call(:url, _, state), do: {:reply, "http://127.0.0.1:#{state.port}/mcp", state}

  @impl true
  def terminate(_, state) do
    Process.exit(state.acceptor, :shutdown)
    :gen_tcp.close(state.listener)
  end

  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker = spawn_link(fn -> receive do: ({:socket, s} -> serve(s, owner)) end)
        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, owner) do
    {head, rest} = read_head(socket, "")
    [request_line | lines] = String.split(head, "\r\n")
    [method, path, _] = String.split(request_line, " ")

    headers =
      Map.new(lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    length = String.to_integer(headers["content-length"] || "0")
    body = read_body(socket, rest, length)

    send(
      owner,
      {:http_request, self(), %{method: method, path: path, headers: headers, body: body}}
    )

    :ok = :inet.setopts(socket, active: :once)
    commands(socket, owner)
  end

  defp read_head(socket, data) do
    case :binary.split(data, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, next} = :gen_tcp.recv(socket, 0, 5000)
        read_head(socket, data <> next)
    end
  end

  defp read_body(_socket, data, length) when byte_size(data) >= length,
    do: binary_part(data, 0, length)

  defp read_body(socket, data, length) do
    {:ok, next} = :gen_tcp.recv(socket, 0, 5000)
    read_body(socket, data <> next, length)
  end

  defp commands(socket, owner) do
    receive do
      {:command, from, ref, {:reply, status, headers, body}} ->
        result =
          :gen_tcp.send(socket, [
            head(status, [{"content-length", byte_size(body)}, {"connection", "close"} | headers]),
            body
          ])

        send(from, {ref, result})
        :gen_tcp.close(socket)

      {:command, from, ref, :sse} ->
        result =
          :gen_tcp.send(
            socket,
            head(200, [{"content-type", "text/event-stream"}, {"transfer-encoding", "chunked"}])
          )

        send(from, {ref, result})
        commands(socket, owner)

      {:command, from, ref, {:chunk, data}} ->
        result =
          :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])

        send(from, {ref, result})
        commands(socket, owner)

      {:tcp_closed, ^socket} ->
        send(owner, {:http_closed, self()})

      {:tcp_error, ^socket, reason} ->
        send(owner, {:http_closed, self(), reason})

      {:tcp, ^socket, _} ->
        :inet.setopts(socket, active: :once)
        commands(socket, owner)
    end
  end

  defp head(status, headers) do
    [
      "HTTP/1.1 #{status} Fixture\r\n",
      Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end),
      "\r\n"
    ]
  end
end
