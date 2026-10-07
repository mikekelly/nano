defmodule Nano.BrowserTest do
  use ExUnit.Case, async: true
  alias Nano.Browser

  test "rejects remote and encrypted endpoints" do
    assert {:error, _} = Browser.connect("wss://example.com/cdp")
    assert {:error, _} = Browser.connect("ws://example.com/cdp")
  end

  test "missing executable returns startup error" do
    assert {:error, _} = Browser.start(executable: "/not/a/browser")
  end

  test "mock server rejects a forged WebSocket handshake" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    worker =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(socket, 0, 1000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: forged\r\n\r\n"
        )

        :gen_tcp.close(socket)
      end)

    assert {:error, _} = Browser.connect("ws://127.0.0.1:#{port}/")
    Task.await(worker)
    :gen_tcp.close(listener)
  end

  test "real Lightpanda renders and interacts with a local JS form" do
    if System.find_executable("lightpanda") do
      server = start_supervised!({Bandit, plug: __MODULE__.Form, port: 0, ip: {127, 0, 0, 1}})
      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      assert {:ok, browser} = Browser.start()
      on_exit(fn -> if Process.alive?(browser), do: Browser.stop(browser) end)
      assert {:ok, _} = Browser.navigate(browser, "http://127.0.0.1:#{port}/")
      assert {:error, {:cdp, _}} = Browser.command(browser, "Unknown.invalid")
      assert {:ok, true} = Browser.fill(browser, "#name", "Nova")
      assert {:ok, true} = Browser.click(browser, "button")

      assert {:ok, "Hello Nova"} =
               Browser.evaluate(browser, "document.querySelector('#result').textContent")

      assert {:ok, page} = Browser.snapshot(browser, max_bytes: 8)
      assert byte_size(page["text"]) <= 8
      assert page["next_offset"] != nil
      assert {:error, {:javascript, _}} = Browser.click(browser, "#missing")
      assert {:error, :unsupported_scheme} = Browser.navigate(browser, "file:///etc/passwd")
      assert {:error, :invalid_offset} = Browser.snapshot(browser, offset: -1)
    end
  end

  test "port watcher terminates its own browser when session is killed" do
    if System.find_executable("lightpanda") do
      {:ok, browser} = Browser.start()
      state = :sys.get_state(browser)
      {:os_pid, os_pid} = Port.info(state.port, :os_pid)
      {:connected, watcher} = Port.info(state.port, :connected)
      watcher_monitor = Process.monitor(watcher)
      Process.exit(browser, :kill)
      assert_receive {:DOWN, ^watcher_monitor, :process, ^watcher, _}, 2000
      assert eventually_gone(os_pid, 100)
    end
  end

  defp eventually_gone(_, 0), do: false

  defp eventually_gone(pid, tries) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(20)
        eventually_gone(pid, tries - 1)

      {_, _} ->
        true
    end
  end

  defmodule Form do
    def init(opts), do: opts

    def call(conn, _) do
      Plug.Conn.send_resp(conn, 200, """
      <!doctype html><title>Local form</title><input id="name"><button onclick="document.querySelector('#result').textContent='Hello '+document.querySelector('#name').value">Go</button><p id="result">Ready for interaction</p>
      """)
    end
  end
end
