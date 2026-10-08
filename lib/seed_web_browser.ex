defmodule SeedWeb.Browser do
  @moduledoc """
  Lightpanda JavaScript rendering without shell interpolation. `fetch(url)` returns
  bounded Markdown (20-second deadline, 2 MB cap); `SeedWeb.fetch(url, browser: true)`
  caches and pages it. `serve(port: 9333)` starts a loopback CDP server, returns its
  owner pid and endpoint, and `stop(pid)` closes it. Choose a free dedicated port;
  no node-wide singleton or implicit 9222. Drive the endpoint with a CDP client
  (Puppeteer/Playwright) for forms/clicks. Server lifetime is independent of an eval;
  it reports exit to the caller. Nothing is compiled into the running node.
  """
  def fetch(url, opts \\ []) do
    with :ok <- SeedWeb.validate_url(url),
         executable when is_binary(executable) <-
           System.find_executable(Keyword.get(opts, :executable, "lightpanda")) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["fetch", "--dump", "markdown", url]
        ])

      collect(
        port,
        "",
        System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 20000),
        Keyword.get(opts, :max_body_bytes, 2_000_000)
      )
    else
      nil -> {:error, :lightpanda_not_installed}
      e -> e
    end
  rescue
    _ -> {:error, :browser_failed}
  end

  defp collect(port, text, deadline, max) do
    receive do
      {^port, {:data, chunk}} ->
        if byte_size(text) + byte_size(chunk) > max do
          close(port)
          {:error, :body_too_large}
        else
          collect(port, text <> chunk, deadline, max)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, text}

      {^port, {:exit_status, status}} ->
        {:error, %{reason: :browser_exit, status: status}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        close(port)
        {:error, :timeout}
    end
  end

  @doc "Start a CDP server on a caller-chosen loopback port; stop explicitly when done."
  def serve(opts) do
    port_number = opts[:port]
    executable = System.find_executable(Keyword.get(opts, :executable, "lightpanda"))

    if is_integer(port_number) and port_number in 1..65535 and executable do
      caller = self()
      ref = make_ref()

      pid =
        spawn(fn ->
          try do
            port =
              Port.open({:spawn_executable, executable}, [
                :binary,
                :exit_status,
                :use_stdio,
                args: ["serve", "--host", "127.0.0.1", "--port", to_string(port_number)]
              ])

            send(caller, {ref, :started})
            server_loop(port, caller)
          rescue
            _ -> send(caller, {ref, :failed})
          end
        end)

      receive do
        {^ref, :started} ->
          {:ok,
           %{
             pid: pid,
             endpoint: "http://127.0.0.1:#{port_number}",
             note: "Process started; CDP client must wait for readiness"
           }}

        {^ref, :failed} ->
          {:error, :browser_failed}
      after
        1000 ->
          Process.exit(pid, :kill)
          {:error, :timeout}
      end
    else
      {:error, :port_required_or_browser_missing}
    end
  end

  def stop(pid) when is_pid(pid), do: send(pid, :stop)

  defp server_loop(port, caller) do
    receive do
      :stop -> close(port)
      {^port, {:data, _}} -> server_loop(port, caller)
      {^port, {:exit_status, status}} -> send(caller, {:seed_web_browser, self(), :exit, status})
    end
  end

  defp close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
