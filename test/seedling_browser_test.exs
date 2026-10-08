defmodule Seedling.BrowserTest do
  use ExUnit.Case, async: true
  @moduletag skip: System.find_executable("lightpanda") == nil
  alias Seedling.{Web, Browser}
  alias Seedling.WebFixture, as: Fixture

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "orion-browser-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{opts: [cache_dir: dir, script_dir: Path.join(dir, "scripts"), timeout: 5000]}
  end

  test "Lightpanda actually executes JavaScript when HTTP is an empty shell", %{opts: opts} do
    {server, url} =
      Fixture.start(fn conn ->
        Fixture.text(
          conn,
          "<html><head><title>Dynamic</title></head><body><div id='root'></div><script>document.querySelector('#root').innerText='Rendered with JavaScript: reliable evidence';</script></body></html>"
        )
      end)

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert {:ok, %{source: "browser", text: text}} = Web.fetch(url, opts)
    assert text =~ "Rendered with JavaScript"
  end

  test "scripted real browser form fill and click change DOM and preserve URL/title", %{
    opts: opts
  } do
    {server, url} =
      Fixture.start(fn conn ->
        Fixture.text(
          conn,
          "<html><head><title>Form test</title></head><body><input id='q'><button id='go' onclick=\"document.getElementById('result').innerText='Answer: '+document.getElementById('q').value\">Go</button><p id='result'></p></body></html>"
        )
      end)

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert {:ok, page} =
             Browser.run(url, [{:fill, "#q", "Elixir \"quotes\""}, {:click, "#go"}], opts)

    assert page.text =~ "Answer: Elixir \"quotes\""
    assert page.title == "Form test"
    assert page.source == "browser_interaction"
    assert {:ok, %{quote: quote}} = Web.cite(page.id, opts)
    assert quote =~ "Answer:"
  end

  test "missing selector and action errors are values", %{opts: opts} do
    assert {:error, %{kind: :invalid_action}} =
             Browser.run("http://localhost", [{:bogus, "selector"}], opts)

    {server, url} = Fixture.start(fn conn -> Fixture.text(conn, "<p>Hi</p>") end)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert {:error, %{kind: :browser}} = Browser.run(url, [{:click, "#missing"}], opts)
  end

  test "loopback CDP serve is usable via WebSocket, and stop frees its port" do
    assert {:ok, server} = Browser.serve(lifetime: 10000)
    on_exit(fn -> Browser.stop(server) end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, server.port, [:binary, active: false, packet: :raw], 1000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(
        socket,
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{server.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      )

    {:ok, handshake} = :gen_tcp.recv(socket, 0, 2000)
    assert handshake =~ "101"
    data = Jason.encode!(%{id: 1, method: "Target.getTargets"})
    mask = <<1, 2, 3, 4>>

    masked =
      for {byte, i} <- Enum.with_index(:binary.bin_to_list(data)),
          into: <<>>,
          do: <<Bitwise.bxor(byte, :binary.at(mask, rem(i, 4)))>>

    :ok = :gen_tcp.send(socket, <<0x81, 0x80 + byte_size(data)>> <> mask <> masked)
    {:ok, frame} = :gen_tcp.recv(socket, 0, 2000)
    assert frame =~ "targetInfos"
    :gen_tcp.close(socket)
    assert :ok = Browser.stop(server)
    Process.sleep(100)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, server.port, [:binary, active: false], 1000)
  end

  test "CDP lifetime expires and conflicting requested ports are rejected" do
    {:ok, first} = Browser.serve(lifetime: 250)
    assert {:error, %{kind: :port_unavailable}} = Browser.serve(port: first.port)
    monitor = Process.monitor(first.pid)
    assert_receive {:DOWN, ^monitor, _, _, :normal}, 1000
  end
end
