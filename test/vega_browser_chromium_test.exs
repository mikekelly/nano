defmodule Vega.BrowserChromiumTest do
  use ExUnit.Case, async: true
  alias Vega.Browser
  @node Vega.Browser.node_runtime()
  @tag skip:
         if(File.regular?(@node) and File.regular?("/usr/bin/chromium"),
           do: false,
           else: "Chromium and native Node22 required"
         )
  test "real CSS viewport/screenshot, keyboard form, permission and notification construction" do
    root =
      Path.join(
        System.tmp_dir!(),
        "vega-browser-chromium-test-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    fixture = spawn(fn -> serve(listener) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(fixture, :kill)
      File.rm_rf(root)
    end)

    {:ok, b} =
      Browser.start(
        backend: :chromium,
        node: @node,
        root: root,
        agent: nil,
        notify: self(),
        lifetime: 30_000
      )

    on_exit(fn ->
      Browser.stop(b)
      wait_stopped(b, 100)
    end)

    origin = "http://127.0.0.1:#{port}"
    assert {:ok, _} = Browser.navigate(b, origin)
    assert {:ok, _} = Browser.viewport(b, 1000, 700)

    assert {:ok, "rgb(0, 128, 0)"} =
             Browser.evaluate(
               b,
               "getComputedStyle(document.querySelector('main')).backgroundColor"
             )

    assert {:ok, %{image: desktop, rendering: :css_pixels}} = Browser.screenshot(b)
    assert desktop["width"] == 1000 and desktop["height"] == 700
    assert {:ok, _} = Browser.viewport(b, 390, 700, mobile: true)

    assert {:ok, "rgb(255, 0, 0)"} =
             Browser.evaluate(
               b,
               "getComputedStyle(document.querySelector('main')).backgroundColor"
             )

    assert {:ok, %{image: mobile, rendering: :css_pixels}} = Browser.screenshot(b)
    assert mobile["width"] == 390 and mobile["height"] == 700
    refute mobile["id"] == desktop["id"]
    assert {:ok, true} = Browser.evaluate(b, "document.querySelector('#name').focus(); true")
    assert {:ok, true} = Browser.press(b, "A")
    assert {:ok, true} = Browser.press(b, "Enter")
    assert {:ok, "Hello A"} = Browser.evaluate(b, "document.querySelector('#out').textContent")
    assert {:ok, true} = Browser.evaluate(b, "window.keyTrusted")

    assert {:ok, _} =
             Browser.command(
               b,
               "Browser.grantPermissions",
               %{origin: origin, permissions: ["notifications"]},
               browser_scope: true
             )

    assert {:ok, "granted"} = Browser.evaluate(b, "Notification.permission")

    assert {:ok, "Vega fixture"} =
             Browser.evaluate(
               b,
               "window.note=new Notification('Vega fixture',{body:'test only'});window.shown=false;window.note.onshow=()=>window.shown=true;window.note.title"
             )

    Process.sleep(500)
    {:ok, shown} = Browser.evaluate(b, "window.shown")

    IO.puts(
      "Chromium notification API constructed, permission granted, show event: #{inspect(shown)} (headless OS delivery not claimed)"
    )

    assert {:ok, nil} = Browser.evaluate(b, "window.note.close()")
    assert :ok = Browser.stop(b)
    assert_receive {:vega_task, %{status: :stopped}}, 5000
    assert {:error, _} = Req.post("http://127.0.0.1:#{b.port}/", retry: false)
  end

  defp wait_stopped(_browser, 0), do: :ok

  defp wait_stopped(browser, attempts) do
    case Browser.status(browser) do
      {:ok, %{status: state}} when state in [:starting, :running] ->
        Process.sleep(50)
        wait_stopped(browser, attempts - 1)

      _ ->
        :ok
    end
  end

  defp serve(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :gen_tcp.recv(socket, 0, 5000)

        body = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        main {background:green;width:100%;height:200px;} @media (max-width:500px){main {background:red;}}
        </style></head><body><main>CSS Pixels</main><form><input id="name"><button>Send</button></form><p id="out"></p>
        <script>window.keyTrusted=false;document.addEventListener('keydown',e=>window.keyTrusted=e.isTrusted);
        document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();document.querySelector('#out').textContent='Hello '+document.querySelector('#name').value;});</script></body></html>
        """

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(socket)
        serve(listener)

      _ ->
        :ok
    end
  end
end
