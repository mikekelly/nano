defmodule WebAccess.BrowserTest do
  use ExUnit.Case, async: true
  alias WebAccess.Browser

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "deneb-browser-test-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp executable(dir, script) do
    path = Path.join(dir, "fake ' lightpanda")
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o700)
    path
  end

  test "returns Markdown, first heading and requested URL; stderr is not content", %{dir: dir} do
    exe = executable(dir, "printf '# Rendered title\\n\\nDynamic body\\n'; echo diagnostic >&2")
    assert {:ok, page} = Browser.fetch("https://example.org", executable: exe)

    assert page == %{
             text: "# Rendered title\n\nDynamic body\n",
             title: "Rendered title",
             url: "https://example.org",
             truncated: false
           }
  end

  test "URL and executable are shell quoted as individual arguments", %{dir: dir} do
    exe = executable(dir, "for arg do last=\"$arg\"; done; printf '%s' \"$last\"")
    url = "https://example.org/a'b?x=$(id);echo&y=1"
    assert {:ok, %{text: ^url}} = Browser.fetch(url, executable: exe)
  end

  test "rejects invalid URLs before execution" do
    for url <- [
          nil,
          42,
          "file:///etc/passwd",
          "ftp://example.org",
          "https://u:p@example.org",
          "https://@example.org",
          "http://",
          "https://example.org\n",
          "http://x:0",
          "http://x:65536",
          "http://x\\evil",
          <<255>>
        ] do
      assert {:error, :invalid_url} = Browser.fetch(url)
    end
  end

  test "invalid options and missing executable return values" do
    for opts <- [%{}, nil, [timeout: 0], [timeout: "1"], [max_bytes: -1], [executable: nil]] do
      assert {:error, _} = Browser.fetch("https://example.org", opts)
    end

    assert {:error, :executable_not_found} =
             Browser.fetch("https://example.org", executable: "/no/such/lightpanda")

    for opts <- [[], [port: -1], [port: 65536], [port: "9222"]] do
      assert {:error, :invalid_port} = Browser.serve(opts)
    end
  end

  test "bounds output on UTF-8 boundary and marks truncation", %{dir: dir} do
    exe = executable(dir, "printf 'abc😀rest'")

    assert {:ok, %{text: "abc", title: "example.org", truncated: true}} =
             Browser.fetch("https://example.org", executable: exe, max_bytes: 5)

    assert {:ok, %{text: "abc😀rest", truncated: false}} =
             Browser.fetch("https://example.org", executable: exe, max_bytes: 11)
  end

  test "title limits use bytes even for one giant combining grapheme", %{dir: dir} do
    heading = "e" <> String.duplicate("́", 1000)
    exe = executable(dir, "printf '# #{heading}\\n'")
    assert {:ok, result} = Browser.fetch("https://example.org", executable: exe)
    assert byte_size(result.title) <= 300
    assert String.valid?(result.title)
  end

  test "uncooperative output is disk bounded", %{dir: dir} do
    exe = executable(dir, "exec /usr/bin/yes x")

    assert {:ok, %{text: text, truncated: true}} =
             Browser.fetch("https://example.org", executable: exe, max_bytes: 100)

    assert byte_size(text) == 100
  end

  test "clamps limits before passing CLI arguments", %{dir: dir} do
    exe = executable(dir, "printf '%s\\n' \"$@\"")

    assert {:ok, %{text: text}} =
             Browser.fetch("https://example.org",
               executable: exe,
               timeout: 99_999,
               max_bytes: 9_999_999
             )

    assert text =~ "--wait-ms\n25000\n"
    assert text =~ "--dump-max-bytes\n24001\n"
  end

  test "nonzero exits preserve bounded diagnostics", %{dir: dir} do
    exe = executable(dir, "echo navigation-failed >&2; exit 22")

    assert {:error, {:exit_status, 22, "navigation-failed\n"}} =
             Browser.fetch("https://example.org", executable: exe)
  end

  test "fetch enforces wall-clock timeout", %{dir: dir} do
    exe = executable(dir, "exec sleep 10")
    start = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Browser.fetch("https://example.org", executable: exe, timeout: 100)

    assert System.monotonic_time(:millisecond) - start < 3000
  end

  test "serve binds localhost and returns a Background job", %{dir: dir} do
    exe = executable(dir, "printf '%s\\n' \"$@\"")
    assert {:ok, job} = Browser.serve(port: 0, executable: exe, notify: self())
    assert_receive {:background, id, %{status: 0}}, 3000
    assert id == job.id
    assert {:ok, output} = Workspace.tail(job.path)
    assert output == "serve\n--host\n127.0.0.1\n--port\n0\n"
  end

  test "serve lifetime is bounded independently of the caller", %{dir: dir} do
    exe = executable(dir, "exec sleep 10")
    assert {:ok, job} = Browser.serve(port: 0, executable: exe, timeout: 100, notify: self())
    assert_receive {:background, id, %{status: status}}, 3000
    assert id == job.id
    assert status in [:timeout, 124, 137]
  end

  test "serve logs are disk bounded", %{dir: dir} do
    exe = executable(dir, "exec /usr/bin/yes x")
    assert {:ok, job} = Browser.serve(port: 0, executable: exe, max_bytes: 100, notify: self())
    assert_receive {:background, id, %{bytes: bytes}}, 3000
    assert id == job.id
    assert bytes <= 1024
  end

  test "Background cancellation actually terminates the CDP OS process", %{dir: dir} do
    pid_path = Path.join(dir, "os.pid")
    exe = executable(dir, "echo $$ > '#{pid_path}'; exec sleep 10")
    assert {:ok, job} = Browser.serve(port: 0, executable: exe, timeout: 5000, notify: self())
    os_pid = wait_for_pid(pid_path, 100)
    Background.cancel(job)
    assert_receive {:background, id, %{status: :cancelled}}, 3000
    assert id == job.id
    assert eventually_dead(os_pid, 100)
  end

  defp wait_for_pid(path, attempts) when attempts > 0 do
    case File.read(path) do
      {:ok, pid} when pid != "" ->
        String.trim(pid)

      _ ->
        Process.sleep(10)
        wait_for_pid(path, attempts - 1)
    end
  end

  defp wait_for_pid(_, 0), do: flunk("fake browser did not start")

  defp eventually_dead(pid, attempts) when attempts > 0 do
    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} ->
        true

      {:ok, text} ->
        if text =~ ~r/^\d+ \(.*\) Z /,
          do: true,
          else:
            (
              Process.sleep(10)
              eventually_dead(pid, attempts - 1)
            )

      _ ->
        false
    end
  end

  defp eventually_dead(_, 0), do: false

  @tag :live_browser
  test "real Lightpanda executes delayed JavaScript against a unique local fixture" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn_link(fn -> serve_fixture(listener) end)

    try do
      assert {:ok, %{text: text}} = Browser.fetch("http://127.0.0.1:#{port}", timeout: 15_000)
      assert text =~ "JavaScript rendered this content"
      refute text =~ "Before script"
    after
      :gen_tcp.close(listener)
      Process.unlink(server)
      Process.exit(server, :kill)
    end
  end

  defp serve_fixture(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :gen_tcp.recv(socket, 0, 2000)

        body =
          "<html><body><main><h1>Before script</h1><script>setTimeout(function(){document.querySelector('h1').textContent='JavaScript rendered this content'},50)</script></main></body></html>"

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(socket)
        serve_fixture(listener)

      _ ->
        :ok
    end
  end
end
