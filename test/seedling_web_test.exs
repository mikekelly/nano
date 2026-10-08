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

  test "automatic bounded browser fallback on JavaScript shell", %{dir: dir} do
    url =
      server(
        "<html><body><div id='root'></div><script>document.getElementById('root').innerHTML = '<p>Rendered evidence</p>';</script></body></html>"
      )

    assert {:ok, result} = Seedling.Web.fetch(url, cache_dir: dir)
    assert result.metadata["method"] == "browser_fallback"
    assert result.text =~ "Rendered evidence"

    assert {:ok, result} =
             Seedling.Web.fetch(url, cache_dir: dir, refresh: true, browser_fallback: false)

    assert result.metadata["method"] == "http"
    assert result.text == ""
    refute Seedling.Web.js_shell?("<p>Short page</p><script>analytics()</script>", "Short page")
  end

  test "durable named-owner completion survives initializer restart and cache deletion", %{
    dir: dir
  } do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    opts = [pending_dir: Path.join(dir, "pending"), cache_dir: Path.join(dir, "cache")]
    record = Seedling.Research.Pending.record("agent_run_durable", "returning-agent", token, opts)
    {:ok, id} = Seedling.Web.Cache.put("citation", %{url: "https://example.org"}, opts)

    assert :pending =
             Seedling.Research.Pending.complete(
               record,
               %{id: id, run_id: "agent_run_durable", status: "completed"},
               Keyword.put(opts, :resolver, fn _ -> nil end)
             )

    assert length(Seedling.Research.Pending.list(opts)) == 1
    File.rm_rf(Keyword.fetch!(opts, :cache_dir))
    owner = self()

    initializer =
      start_supervised!(
        {Seedling.Research.Pending,
         opts ++ [resolver: fn "returning-agent" -> owner end, scan_interval: 10]}
      )

    assert_receive {:research, ^token, {:ok, %{id: restored}}}, 5000
    assert {:ok, %{text: "citation"}} = Seedling.Web.read(restored, opts)
    assert Seedling.Research.Pending.list(opts) == []
    assert Process.alive?(initializer)
  end

  test "initializer reattaches a saved remote research run", %{dir: dir} do
    body =
      Jason.encode!(%{id: "agent_run_resume", status: "completed", output: %{text: "evidence"}})

    owner = self()

    opts = [
      pending_dir: Path.join(dir, "pending"),
      cache_dir: dir,
      api_key: "test-key",
      base_url: server(body)
    ]

    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    record = Seedling.Research.Pending.record("agent_run_resume", "named-agent", token, opts)
    assert :ok = Seedling.Research.Pending.save(record, opts)

    start_supervised!(
      {Seedling.Research.Pending,
       opts ++ [resolver: fn "named-agent" -> owner end, scan_interval: 10]}
    )

    assert_receive {:research, ^token, {:ok, %{status: "completed"}}}, 5000
    assert Seedling.Research.Pending.list(opts) == []
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
