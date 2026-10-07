defmodule Nano.Browser do
  @moduledoc """
  Local Lightpanda CDP sessions, without extra dependencies. `start_link/1` is
  suitable for a supervisor; `start/1` starts an unlinked background owner.

      {:ok, browser} = Nano.Browser.start()
      Nano.Browser.navigate(browser, "https://example.com")
      Nano.Browser.snapshot(browser)
      Nano.Browser.stop(browser)

  Each owner serializes commands and owns its browser OS process and TCP socket.
  `connect/2` instead connects to an existing **local, unencrypted** ws endpoint.
  Only ws://127.0.0.1 endpoints are accepted; this is not a general WebSocket client.
  JavaScript runs in the page's security context, not an isolation sandbox.
  """
  use GenServer
  import Bitwise

  def start(opts \\ []), do: GenServer.start(__MODULE__, opts)
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def connect(url, opts \\ []), do: start(Keyword.put(opts, :endpoint, url))
  def stop(pid), do: GenServer.stop(pid)

  def command(pid, method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    GenServer.call(pid, {:command, method, params, timeout}, timeout + 1000)
  catch
    :exit, reason -> {:error, {:session_exit, reason}}
  end

  def navigate(pid, url) do
    if URI.parse(url).scheme in ["http", "https"],
      do: command(pid, "Page.navigate", %{"url" => url}),
      else: {:error, :unsupported_scheme}
  end

  def evaluate(pid, js, opts \\ []) do
    case command(
           pid,
           "Runtime.evaluate",
           %{"expression" => js, "returnByValue" => true, "awaitPromise" => true},
           opts
         ) do
      {:ok, %{"exceptionDetails" => details}} -> {:error, {:javascript, details}}
      {:ok, %{"result" => result}} -> {:ok, Map.get(result, "value")}
      other -> other
    end
  end

  def click(pid, selector),
    do:
      evaluate(
        pid,
        "(()=>{const e=document.querySelector(#{Jason.encode!(selector)});if(!e)throw Error('selector not found');e.click();return true})()"
      )

  def fill(pid, selector, value),
    do:
      evaluate(
        pid,
        "(()=>{const e=document.querySelector(#{Jason.encode!(selector)});if(!e)throw Error('selector not found');e.value=#{Jason.encode!(value)};e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true})()"
      )

  @doc "Bounded readable DOM text (not Markdown or visual/accessibility rendering)."
  def snapshot(pid, opts \\ []) do
    limit = Keyword.get(opts, :max_bytes, 12_000) |> max(1) |> min(30_000)
    offset = Keyword.get(opts, :offset, 0)

    if not is_integer(offset) or offset < 0 do
      {:error, :invalid_offset}
    else
      # Slice in the browser before transport; Unicode byte cap is enforced again below.
      js =
        "(()=>{const t=document.body?.innerText||document.body?.textContent||'';return {url:location.href,title:document.title,text:t.slice(#{offset},#{offset + limit}),total:t.length}})()"

      case evaluate(pid, js) do
        {:ok, %{"text" => text} = page} ->
          bounded =
            text
            |> String.to_charlist()
            |> Enum.reduce_while({[], 0}, fn cp, {acc, n} ->
              b = byte_size(<<cp::utf8>>)
              if n + b > limit, do: {:halt, {acc, n}}, else: {:cont, {[cp | acc], n + b}}
            end)
            |> elem(0)
            |> Enum.reverse()
            |> List.to_string()

          # CDP/JS offsets count UTF-16 code units, not UTF-8 bytes.
          units =
            div(byte_size(:unicode.characters_to_binary(bounded, :utf8, {:utf16, :little})), 2)

          next = offset + units

          if bounded == "" and offset < page["total"] do
            {:error, :character_exceeds_byte_limit}
          else
            {:ok,
             Map.merge(page, %{
               "text" => bounded,
               "offset" => offset,
               "next_offset" => if(next < page["total"], do: next, else: nil)
             })}
          end

        other ->
          other
      end
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case launch(opts) do
      {:ok, port, endpoint} ->
        case initialize(port, endpoint) do
          {:ok, _} = ok ->
            ok

          error ->
            if port, do: close_browser(port)
            error
        end

      error ->
        {:stop, {:browser_start, error}}
    end
  end

  defp initialize(port, endpoint) do
    with {:ok, socket} <- websocket(endpoint),
         state = %{port: port, socket: socket, id: 0, session: nil},
         {{:ok, %{"targetId" => target}}, state} <-
           request(state, "Target.createTarget", %{"url" => "about:blank"}, 5000),
         {{:ok, %{"sessionId" => session}}, state} <-
           request(
             state,
             "Target.attachToTarget",
             %{"targetId" => target, "flatten" => true},
             5000
           ) do
      {:ok, state |> Map.put(:session, session) |> Map.put(:target, target)}
    else
      error -> {:stop, {:browser_start, error}}
    end
  end

  defp launch(opts) do
    case opts[:endpoint] do
      nil ->
        executable = opts[:executable] || System.find_executable("lightpanda")

        if executable do
          {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
          {:ok, {_, number}} = :inet.sockname(listener)
          :gen_tcp.close(listener)

          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: ["serve", "--host", "127.0.0.1", "--port", to_string(number)]
            ])

          case discover(number, 100) do
            {:ok, url} ->
              {:ok, port, url}

            error ->
              close_browser(port)
              error
          end
        else
          {:error, :missing_lightpanda}
        end

      url ->
        {:ok, nil, url}
    end
  end

  defp discover(_, 0), do: {:error, :startup_timeout}

  defp discover(port, retries) do
    case Req.get("http://127.0.0.1:#{port}/json/version",
           retry: false,
           connect_options: [timeout: 100],
           receive_timeout: 200
         ) do
      {:ok, %{body: %{"webSocketDebuggerUrl" => url}}} ->
        {:ok, url}

      _ ->
        Process.sleep(50)
        discover(port, retries - 1)
    end
  end

  defp websocket(url) do
    uri = URI.parse(url)

    if uri.scheme == "ws" and uri.host == "127.0.0.1" do
      with {:ok, socket} <-
             :gen_tcp.connect(
               {127, 0, 0, 1},
               uri.port || 80,
               [:binary, active: false, packet: :http_bin],
               5000
             ) do
        key = Base.encode64(:crypto.strong_rand_bytes(16))
        path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

        :ok =
          :gen_tcp.send(
            socket,
            "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{uri.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
          )

        expected =
          Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        with {:ok, {:http_response, _, 101, _}} <- :gen_tcp.recv(socket, 0, 5000),
             {:ok, headers} <- headers(socket, %{}),
             true <- headers["sec-websocket-accept"] == expected do
          :inet.setopts(socket, packet: :raw)
          {:ok, socket}
        else
          error ->
            :gen_tcp.close(socket)
            {:error, {:handshake, error}}
        end
      end
    else
      {:error, :local_ws_endpoint_required}
    end
  end

  defp headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, Map.put(acc, String.downcase(to_string(name)), value))

      error ->
        error
    end
  end

  @impl true
  def handle_call({:command, method, params, timeout}, _, state) do
    {reply, state} = request(state, method, params, timeout)

    case reply do
      {:error, {:cdp, _}} -> {:reply, reply, state}
      {:error, _} -> {:stop, :normal, reply, state}
      _ -> {:reply, reply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:browser_exit, status}, state}

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state) do
    if state.port == nil and state[:target] do
      request(%{state | session: nil}, "Target.closeTarget", %{"targetId" => state.target}, 500)
    end

    :gen_tcp.close(state.socket)
    if state.port, do: close_browser(state.port)
  end

  defp close_browser(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
        if Port.info(port), do: Port.close(port)

      nil ->
        :ok
    end
  end

  defp request(state, method, params, timeout) do
    id = state.id + 1
    msg = %{"id" => id, "method" => method, "params" => params}
    msg = if state.session, do: Map.put(msg, "sessionId", state.session), else: msg

    result =
      with :ok <- send_frame(state.socket, 1, Jason.encode!(msg)),
           do: response(state.socket, id, System.monotonic_time(:millisecond) + timeout)

    {result, %{state | id: id}}
  end

  defp send_frame(socket, opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    n = byte_size(payload)

    length =
      cond do
        n < 126 -> <<1::1, n::7>>
        n < 65536 -> <<254, n::16>>
        true -> <<255, n::64>>
      end

    masked =
      for {b, i} <- Enum.with_index(:binary.bin_to_list(payload)),
          into: <<>>,
          do: <<bxor(b, :binary.at(mask, rem(i, 4)))>>

    :gen_tcp.send(socket, [<<128 + opcode>>, length, mask, masked])
  end

  defp response(socket, id, deadline) do
    case frame(socket, deadline) do
      {:ok, 1, payload} ->
        case Jason.decode(payload) do
          {:ok, %{"id" => ^id, "error" => error}} -> {:error, {:cdp, error}}
          {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
          {:ok, _} -> response(socket, id, deadline)
          error -> error
        end

      {:ok, 9, payload} ->
        send_frame(socket, 10, payload)
        response(socket, id, deadline)

      {:ok, 8, _} ->
        {:error, :closed}

      {:ok, _, _} ->
        {:error, :unsupported_frame}

      error ->
        error
    end
  end

  defp recv(socket, n, deadline),
    do: :gen_tcp.recv(socket, n, max(1, deadline - System.monotonic_time(:millisecond)))

  defp frame(socket, deadline) do
    with {:ok, <<fin::1, _::3, opcode::4, masked::1, n::7>>} <- recv(socket, 2, deadline),
         true <- fin == 1 and masked == 0,
         {:ok, n} <- length(socket, n, deadline),
         true <- n <= 5_000_000,
         {:ok, data} <- if(n == 0, do: {:ok, ""}, else: recv(socket, n, deadline)) do
      {:ok, opcode, data}
    else
      false -> {:error, :unsupported_or_oversized_frame}
      error -> error
    end
  end

  defp length(socket, 126, deadline) do
    with {:ok, <<n::16>>} <- recv(socket, 2, deadline), do: {:ok, n}
  end

  defp length(socket, 127, deadline) do
    with {:ok, <<n::64>>} <- recv(socket, 8, deadline), do: {:ok, n}
  end

  defp length(_, n, _), do: {:ok, n}
end
