defmodule Seedling.Browser do
  @moduledoc """
  Lightpanda rendering and trusted scripted interactions, with deadlines and bounded output.
  `fetch/2` is usually called by `Seedling.Web.fetch(url, mode: :browser)`.
  `run(url, [{:fill, "#q", "elixir"}, {:click, "#submit"}])` executes a fresh isolated page.
  No Node/npm is required. `serve/1` exposes an owned loopback CDP server for external
  Puppeteer-style clients; stop it with `stop/1`. See `docs/web-search.md`.
  """
  alias Seedling.Web.{Store, Transport}

  def available?, do: System.find_executable("lightpanda") != nil

  def fetch(url, opts \\ []) do
    with :ok <- Transport.url(url),
         :ok <- available(),
         {:ok, raw} <- command(fetch_args(url, opts), Keyword.get(opts, :timeout, 20000)) do
      parse_fetch(raw, url)
    end
  end

  @doc "Start a detached Lightpanda render using Seedling.Background; result arrives by stable agent name."
  def fetch_async(url, opts \\ []) do
    with :ok <- Transport.url(url),
         :ok <- available(),
         {:ok, {:name, owner}} <- Seedling.Web.Owner.resolve(Keyword.get(opts, :owner)) do
      timeout = Keyword.get(opts, :timeout, 60000)
      args = fetch_args(url, Keyword.put(opts, :timeout, timeout))

      cmd =
        Enum.map_join(
          [System.find_executable("lightpanda") | args],
          " ",
          &Seedling.Tools.quote_arg/1
        )

      Seedling.Background.start(
        cmd,
        Keyword.merge(opts, owner: owner, timeout: timeout + 1000, cwd: "/tmp")
      )
    else
      {:ok, {:pid, _}} -> {:error, %{kind: :named_owner_required, hint: "Pass owner: agent_name"}}
      error -> error
    end
  end

  @doc "Read a successful background-render completion as a bounded cached page (not raw CLI JSON)."
  def read_background(result, opts \\ [])

  def read_background(%{status: 0, output: path}, opts) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= 8_000_000,
         {:ok, raw} <- File.read(path),
         {:ok, doc} <- parse_fetch(raw, nil),
         {:ok, rec} <-
           Store.put(
             "browser_job:" <> path,
             doc.text,
             %{
               "url" => doc.url,
               "source" => doc.source,
               "content_truncated" => doc.content_truncated
             },
             opts
           ) do
      Store.page(rec, opts)
    else
      false -> {:error, %{kind: :response_too_large}}
      error -> error
    end
  end

  def read_background(result, _opts),
    do:
      {:error,
       %{
         kind: :browser_background,
         status: Map.get(result, :status),
         reason: Map.get(result, :reason)
       }}

  defp fetch_args(url, opts) do
    timeout = Keyword.get(opts, :timeout, 20000)

    [
      "fetch",
      "--dump",
      "markdown",
      "--json",
      "--fail-on-http-error",
      "--strip-mode",
      "clutter",
      "--dump-max-bytes",
      to_string(Keyword.get(opts, :max_download_bytes, 2_000_000)),
      "--terminate-ms",
      to_string(timeout),
      "--http-timeout",
      to_string(timeout),
      "--log-level",
      "fatal",
      url
    ]
  end

  defp parse_fetch(raw, url) do
    with {:ok, data} when is_map(data) <- Jason.decode(raw),
         nil <- data["error"],
         true <- is_integer(data["http_status"]) and data["http_status"] in 200..299,
         text when is_binary(text) <- data["content"] do
      {:ok,
       %{
         text: text,
         url: data["url"] || url,
         title: nil,
         source: "browser",
         content_truncated: String.contains?(text, "[truncated]")
       }}
    else
      _ -> {:error, %{kind: :browser_render, hint: "Lightpanda navigation/rendering failed"}}
    end
  end

  @doc "Run an isolated page's actions. Actions may have side effects; only submit forms deliberately."
  def run(url, actions, opts \\ []) do
    with :ok <- Transport.url(url), :ok <- available(), {:ok, commands} <- actions(actions) do
      cap = Keyword.get(opts, :max_download_bytes, 2_000_000)

      script =
        "const page = new Page();\nawait page.goto(" <>
          Jason.encode!(url) <>
          ");\n" <>
          commands <>
          "\nconsole.log(JSON.stringify(page.evaluate(" <>
          Jason.encode!(
            "JSON.stringify({url:location.href,title:document.title,text:document.body.innerText.slice(0,#{cap})})"
          ) <> ")));\n"

      dir = Keyword.get(opts, :script_dir, "/tmp/orion-web/scripts")

      path =
        Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".js")

      with :ok <- Seedling.Tools.write(path, script) do
        result =
          command(
            [
              "run",
              path,
              "--watchdog-ms",
              to_string(Keyword.get(opts, :timeout, 20000)),
              "--log-level",
              "fatal"
            ],
            Keyword.get(opts, :timeout, 20000)
          )

        File.rm(path)

        with {:ok, raw} <- result,
             {:ok, encoded} <- Jason.decode(String.trim(raw)),
             {:ok, data} <- decode_run(encoded),
             text when is_binary(text) <- data["text"],
             {:ok, rec} <-
               Store.put(
                 url <> ":interaction:" <> path,
                 Store.clip(text, cap),
                 %{
                   "url" => data["url"],
                   "title" => data["title"],
                   "source" => "browser_interaction",
                   "content_truncated" => String.length(text) >= cap
                 },
                 opts
               ) do
          Store.page(rec, opts)
        else
          {:error, _} = error -> error
          _ -> {:error, %{kind: :browser_script_output}}
        end
      end
    end
  end

  defp decode_run(data) when is_map(data), do: {:ok, data}
  defp decode_run(data) when is_binary(data), do: Jason.decode(data)
  defp decode_run(_), do: {:error, %{kind: :browser_script_output}}

  defp actions(list) when is_list(list) and length(list) <= 50 do
    Enum.reduce_while(list, {:ok, ""}, fn action, {:ok, acc} ->
      case action do
        {:click, selector} when is_binary(selector) ->
          {:cont, {:ok, acc <> "page.click(#{Jason.encode!(selector)});\n"}}

        {:fill, selector, text} when is_binary(selector) and is_binary(text) ->
          {:cont, {:ok, acc <> "page.fill(#{Jason.encode!(selector)},#{Jason.encode!(text)});\n"}}

        {:evaluate, expr} when is_binary(expr) ->
          {:cont, {:ok, acc <> "page.evaluate(#{Jason.encode!(expr)});\n"}}

        {:goto, url} when is_binary(url) ->
          case Transport.url(url) do
            :ok -> {:cont, {:ok, acc <> "await page.goto(#{Jason.encode!(url)});\n"}}
            error -> {:halt, error}
          end

        _ ->
          {:halt,
           {:error,
            %{
              kind: :invalid_action,
              hint:
                "Use {:click, selector}, {:fill, selector, value}, {:evaluate, js} or {:goto, url}"
            }}}
      end
    end)
  end

  defp actions(_), do: {:error, %{kind: :invalid_actions}}

  @doc "Start an owned loopback CDP server. :port defaults to a free ephemeral port; lifetime defaults to 5 minutes."
  def serve(opts \\ []), do: Seedling.Browser.Server.start(opts)
  def stop(%{pid: pid}), do: stop(pid)

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp available, do: if(available?(), do: :ok, else: {:error, %{kind: :browser_unavailable}})

  defp command(args, timeout) do
    cmd =
      Enum.map_join(
        [System.find_executable("lightpanda") | args],
        " ",
        &Seedling.Tools.quote_arg/1
      )

    result = Seedling.Tools.sh(cmd, timeout: timeout + 1000, cwd: "/tmp")

    cond do
      result.timed_out -> {:error, %{kind: :timeout, timeout_ms: timeout}}
      result.status != 0 -> {:error, %{kind: :browser, exit_status: result.status}}
      true -> File.read(result.full_output)
    end
  rescue
    _ -> {:error, %{kind: :browser}}
  end
end

defmodule Seedling.Browser.Server do
  @moduledoc false
  use GenServer

  def start(opts) do
    executable = System.find_executable("lightpanda")

    if executable do
      with {:ok, owner} <- Seedling.Web.Owner.resolve(Keyword.get(opts, :owner)),
           {:ok, socket} <-
             :gen_tcp.listen(Keyword.get(opts, :port, 0), [
               :binary,
               ip: {127, 0, 0, 1},
               active: false
             ]),
           {:ok, {_, port}} <- :inet.sockname(socket) do
        :gen_tcp.close(socket)

        case GenServer.start(__MODULE__, {executable, port, owner, opts}) do
          {:ok, pid} ->
            if ready(pid, port, System.monotonic_time(:millisecond) + 3000),
              do: {:ok, %{pid: pid, port: port, endpoint: "ws://127.0.0.1:#{port}"}},
              else:
                (
                  Seedling.Browser.stop(pid)
                  {:error, %{kind: :cdp_start}}
                )

          _ ->
            {:error, %{kind: :cdp_start}}
        end
      else
        _ -> {:error, %{kind: :port_unavailable}}
      end
    else
      {:error, %{kind: :browser_unavailable}}
    end
  end

  def init({executable, port, owner, opts}) do
    Process.flag(:trap_exit, true)
    ref = Seedling.Web.Owner.monitor(owner)
    Process.send_after(self(), :expire, Keyword.get(opts, :lifetime, 300_000))

    child =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["serve", "--host", "127.0.0.1", "--port", to_string(port), "--log-level", "fatal"]
      ])

    {:ok, %{port: child, owner: ref}}
  end

  def handle_info({port, {:data, _}}, %{port: port} = state), do: {:noreply, state}
  def handle_info({port, {:exit_status, _}}, %{port: port} = state), do: {:stop, :normal, state}
  def handle_info({:DOWN, ref, _, _, _}, %{owner: ref} = state), do: {:stop, :normal, state}
  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _, _}, state), do: {:stop, :normal, state}

  def terminate(_, state) do
    if info = Port.info(state.port, :os_pid) do
      {:os_pid, os_pid} = info
      System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
      Port.close(state.port)
    end
  end

  defp ready(pid, port, deadline) do
    cond do
      not Process.alive?(pid) or System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            true

          _ ->
            Process.sleep(25)
            ready(pid, port, deadline)
        end
    end
  end
end
