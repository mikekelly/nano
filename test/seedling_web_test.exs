defmodule Seedling.WebTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "lyra-web-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp server(body) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(socket)
    pid = spawn(fn -> serve(socket, body) end)

    on_exit(fn ->
      :gen_tcp.close(socket)
      Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp serve(socket, body) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        :gen_tcp.recv(client, 0, 5000)

        :gen_tcp.send(
          client,
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(client)
        serve(socket, body)

      _ ->
        :ok
    end
  end

  test "HTTP readability, paging and offline cache", %{dir: dir} do
    url =
      server(
        "<html><nav>junk</nav><main><p>Evidence &amp; facts.</p><script>bad()</script><p>Second paragraph.</p></main></html>"
      )

    assert {:ok, first} = Seedling.Web.fetch(url, cache_dir: dir, limit: 8)
    assert first.text == "Evidence"
    assert first.next_offset == 8
    assert {:ok, rest} = Seedling.Web.read(first.id, cache_dir: dir, offset: 8)
    assert rest.text =~ "& facts."
    refute rest.text =~ "bad"
    assert {:ok, again} = Seedling.Web.fetch(url, cache_dir: dir)
    assert again.id == first.id

    assert {:error, {:invalid_offset, _}} =
             Seedling.Web.read(first.id, cache_dir: dir, offset: 9999)

    assert {:error, :invalid_url} = Seedling.Web.fetch("file:///etc/passwd")
  end

  test "bounded process output and timeout" do
    assert {:error, {:body_too_large, 4}} =
             Seedling.Web.Transport.run("printf", ["123456"], max_bytes: 4)

    assert {:error, :timeout} = Seedling.Web.Transport.run("sleep", ["2"], timeout: 5)
  end

  test "search compact results and async research events", %{dir: dir} do
    body =
      Jason.encode!(%{
        results: [
          %{
            id: "a",
            url: "https://example.com",
            title: "Example",
            text: "not returned",
            highlights: ["quote"]
          }
        ]
      })

    opts = [api_key: "test-key", base_url: server(body), cache_dir: dir]
    assert {:ok, %{results: [result], id: id}} = Seedling.Search.query("test", opts)
    refute Map.has_key?(result, "text")
    assert {:ok, _} = Seedling.Web.read(id, cache_dir: dir)

    run =
      Jason.encode!(%{
        id: "agent_run_test",
        status: "completed",
        output: %{content: "Cited result"}
      })

    assert {:ok, %{ref: ref}} =
             Seedling.Research.start("test", Keyword.put(opts, :base_url, server(run)))

    assert_receive {:research_started, ^ref, "agent_run_test"}, 5000
    assert_receive {:research, ^ref, {:ok, %{status: "completed", id: cache_id}}}, 5000
    assert {:ok, _} = Seedling.Web.read(cache_id, cache_dir: dir)
    assert {:error, :missing_exa_api_key} = Seedling.Search.query("test", api_key: "")
    assert {:error, :invalid_run_id} = Seedling.Research.status("../../etc/passwd")
  end
end
