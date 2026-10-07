defmodule Vega.BrowserTest do
  use ExUnit.Case, async: true
  alias Vega.Browser
  @node System.get_env("VEGA_BROWSER_NODE") || "/tmp/vega-browser-tools/node"

  test "missing prerequisites and option validation are explicit" do
    assert {:error, :node_22_and_lightpanda_required} = Browser.start(node: "/does/not/exist")
    assert {:error, :http_url_required} = Browser.navigate(%{}, "file:///etc/passwd")
    assert {:error, :invalid_dom_options} = Browser.dom(%{}, limit: 16001)

    assert {:error, :invalid_timeout_or_request_too_large} =
             Browser.evaluate(%{}, "1", timeout: 0)
  end

  @tag :real_browser
  @tag skip:
         if(File.regular?(@node) and File.regular?("/usr/local/bin/lightpanda"),
           do: false,
           else: "native Node>=22 and Lightpanda required"
         )
  test "real JS DOM, form, click, paging, screenshot probe, resume and cleanup" do
    if File.regular?(@node) and File.regular?("/usr/local/bin/lightpanda") do
      {:ok, socket} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_, port}} = :inet.sockname(socket)
      server = spawn(fn -> serve(socket) end)

      root =
        Path.join(
          System.tmp_dir!(),
          "vega-browser-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        )

      on_exit(fn ->
        :gen_tcp.close(socket)
        Process.exit(server, :kill)
        File.rm_rf(root)
      end)

      parent = self()

      {initiator, ref} =
        spawn_monitor(fn ->
          result =
            Browser.start(node: @node, root: root, agent: nil, notify: parent, lifetime: 30_000)

          send(parent, {:started, result})
        end)

      assert_receive {:started, {:ok, b}}, 15000
      assert_receive {:DOWN, ^ref, :process, ^initiator, :normal}, 1000

      on_exit(fn -> Browser.stop(b) end)
      assert {:ok, %{"title" => "JS fixture"}} = Browser.navigate(b, "http://127.0.0.1:#{port}/")
      assert {:ok, "Ready🙂"} = Browser.evaluate(b, "document.querySelector('#out').textContent")
      before_image = Browser.screenshot(b)
      assert {:ok, true} = Browser.fill(b, "#name", "Alice ' <&🙂")
      assert {:ok, true} = Browser.click(b, "#submit")

      assert {:ok, "Hello Alice ' <&🙂"} =
               Browser.evaluate(b, "document.querySelector('#out').textContent")

      assert {:ok, 1} = Browser.evaluate(b, "window.inputs")
      assert {:ok, %{"text" => html}} = Browser.dom(b, mode: :html)
      assert html =~ "Hello Alice"
      assert {:ok, %{"text" => first, "next" => 3}} = Browser.dom(b, limit: 3)
      assert String.length(first) == 3
      assert {:error, %{"kind" => "javascript"}} = Browser.click(b, "#missing")
      assert {:error, %{"kind" => "result_too_large"}} = Browser.evaluate(b, "'a'.repeat(60000)")

      assert {:error, :invalid_timeout_or_request_too_large} =
               Browser.evaluate(b, String.duplicate("a", 100_001))

      case Browser.screenshot(b) do
        {:ok, %{image: ref, rendering: :lightpanda_text_layout}} ->
          assert ref["mime"] == "image/png"
          assert {:ok, %{image: previous}} = before_image
          refute ref["id"] == previous["id"]
          assert ref["width"] > 0
          assert {:ok, bytes, "image/png"} = Vega.Images.fetch(ref["id"])
          assert {:ok, "image/png", _, _} = Vega.Images.dimensions(bytes)
          <<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>> = bytes
          chunks = png_chunks(rest)
          compressed = for {"IDAT", data} <- chunks, into: <<>>, do: data
          assert byte_size(:zlib.uncompress(compressed)) > 0

          IO.puts(
            "Lightpanda screenshot: validated text-layout PNG #{ref["width"]}x#{ref["height"]}, #{ref["bytes"]} bytes (not CSS rendering)"
          )

        {:error, %{"kind" => "unsupported", "feature" => "screenshot"} = reason} ->
          IO.puts("Lightpanda screenshot unsupported: #{inspect(reason)}")

        {:error, :unsupported_screenshot_no_png} ->
          IO.puts("Lightpanda screenshot unsupported: no PNG data")
      end

      assert {:ok, resumed} = Browser.resume(b.dir)

      assert {:ok, "Hello Alice ' <&🙂"} =
               Browser.evaluate(resumed, "document.querySelector('#out').textContent")

      assert :ok = Browser.stop(b)
      assert_receive {:vega_task, %{status: :stopped}}, 5000
      assert {:error, :session_not_running} = Browser.evaluate(b, "1")
      assert {:error, _} = Req.post("http://127.0.0.1:#{b.port}/", retry: false)
    else
      IO.puts("Real browser test not exercised: Node>=22 / Lightpanda absent")
    end
  end

  defp png_chunks(<<0::32, "IEND", crc::32>>) do
    assert crc == :erlang.crc32("IEND")
    []
  end

  defp png_chunks(
         <<size::32, type::binary-size(4), data::binary-size(size), crc::32, rest::binary>>
       ) do
    assert crc == :erlang.crc32(type <> data)
    [{type, data} | png_chunks(rest)]
  end

  defp serve(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        :gen_tcp.recv(client, 0, 5000)

        body = """
        <!doctype html><html><head><title>JS fixture</title></head><body>
        <form><input id="name"><button id="submit">Send</button></form><p id="out"></p>
        <script>
        window.inputs=0;
        document.querySelector('#out').textContent='Ready🙂';
        document.querySelector('#name').addEventListener('input',()=>window.inputs++);
        document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();document.querySelector('#out').textContent='Hello '+document.querySelector('#name').value;});
        </script></body></html>
        """

        :gen_tcp.send(
          client,
          "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(client)
        serve(socket)

      _ ->
        :ok
    end
  end
end
