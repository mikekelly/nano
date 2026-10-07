defmodule Vega.Browser do
  @moduledoc """
  Stateful Lightpanda (default) or Chromium CDP automation via Node >=22 bridge.

      {:ok, browser} = Vega.Browser.start(node: "/path/to/node", agent: "vega")
      {:ok, _} = Vega.Browser.navigate(browser, "https://example.com")
      Vega.Browser.dom(browser)
      Vega.Browser.click(browser, "button")
      Vega.Browser.fill(browser, "input[name=q]", "hello")
      Vega.Browser.stop(browser)

  Retain handles across eval/agent restarts, or recover with `resume(dir)`.
  Vega.Tasks guards the entire process group on stop, crash or deadline.
  Completion is the named `{:vega_task, record}` event. Sessions are NOT
  automatically restarted: after backend/BEAM restart start a new session.
  DOM/script output is untrusted data. See docs/vega-browser.md.
  """
  def start(opts \\ []) do
    node =
      Keyword.get(
        opts,
        :node,
        System.get_env("VEGA_BROWSER_NODE") || System.find_executable("node")
      )

    backend = Keyword.get(opts, :backend, :lightpanda)

    binary =
      Keyword.get(
        opts,
        :binary,
        if(backend == :chromium,
          do: "/usr/bin/chromium",
          else: Keyword.get(opts, :lightpanda, "/usr/local/bin/lightpanda")
        )
      )

    dir =
      Path.join(
        Keyword.get(opts, :root, "/tmp/vega-browser-sessions"),
        Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    config = %{
      backend: backend,
      binary: binary,
      profile: Path.join(dir, "profile"),
      token: token,
      ready: Path.join(dir, "ready.json")
    }

    script = Keyword.get(opts, :script, Path.join(:code.priv_dir(:nano), "vega_browser.mjs"))

    if backend in [:lightpanda, :chromium] and is_binary(node) and File.regular?(node) and
         File.regular?(binary) do
      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700),
           :ok <- Vega.Files.write(Path.join(dir, "config.json"), Jason.encode!(config)),
           :ok <- File.chmod(Path.join(dir, "config.json"), 0o600),
           {:ok, task} <-
             Vega.Tasks.start(
               Enum.map_join([node, script, Path.join(dir, "config.json")], " ", &quote_sh/1),
               root: Path.join(dir, "tasks"),
               agent: Keyword.get(opts, :agent),
               notify: Keyword.get(opts, :notify, self()),
               timeout: Keyword.get(opts, :lifetime, 600_000)
             ),
           :ok <- Vega.Files.write(Path.join(dir, "task.term"), :erlang.term_to_binary(task)) do
        case await_ready(dir, task, 250) do
          {:ok, browser} ->
            {:ok, browser}

          error ->
            Vega.Tasks.stop(task)
            error
        end
      end
    else
      {:error,
       if(backend == :chromium,
         do: :node_22_and_chromium_required,
         else: :node_22_and_lightpanda_required
       )}
    end
  end

  @doc "Recovers a live session handle from its directory, without restarting it."
  def resume(dir) do
    with {:ok, config} <- File.read(Path.join(dir, "config.json")),
         {:ok, config} <- Jason.decode(config),
         {:ok, ready} <- File.read(Path.join(dir, "ready.json")),
         {:ok, ready} <- Jason.decode(ready),
         {:ok, task} <- File.read(Path.join(dir, "task.term")) do
      {:ok,
       %{
         dir: dir,
         port: ready["port"],
         token: config["token"],
         backend: if(config["backend"] == "chromium", do: :chromium, else: :lightpanda),
         task: :erlang.binary_to_term(task, [:safe])
       }}
    end
  rescue
    _ -> {:error, :invalid_session}
  end

  def stop(browser), do: Vega.Tasks.stop(browser.task)
  def status(browser), do: Vega.Tasks.status(browser.task)

  def navigate(browser, url, opts \\ []) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         uri.userinfo == nil,
       do: request(browser, %{op: "navigate", url: url}, opts),
       else: {:error, :http_url_required}
  end

  @doc "Runs caller-supplied JS (not shell code). Bounded JSON-by-value result."
  def evaluate(browser, expression, opts \\ []) when is_binary(expression),
    do: request(browser, %{op: "evaluate", expression: expression}, opts)

  @doc "Unicode-paged DOM snapshot: URL/title, HTML or text, total and next."
  def dom(browser, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 8000)
    mode = Keyword.get(opts, :mode, :text)

    if is_integer(offset) and offset >= 0 and is_integer(limit) and limit in 1..16000 and
         mode in [:text, :html] do
      source =
        if mode == :html,
          do: "document.documentElement.outerHTML",
          else: "document.body?.textContent || ''"

      evaluate(
        browser,
        "(() => {const chars=Array.from(#{source});return {url:location.href,title:document.title,text:chars.slice(#{offset},#{offset + limit}).join(''),total:chars.length,next:chars.length>#{offset + limit}?#{offset + limit}:null};})()",
        opts
      )
    else
      {:error, :invalid_dom_options}
    end
  end

  @doc "DOM click: element.click(), not a trusted mouse/coordinate event."
  def click(browser, selector, opts \\ []),
    do: element_action(browser, selector, "el.click(); return true;", opts)

  @doc "Sets value and dispatches bubbling input/change events (not keyboard events)."
  def fill(browser, selector, value, opts \\ []) when is_binary(value),
    do:
      element_action(
        browser,
        selector,
        "if(!('value' in el)) throw Error('not a form control'); el.value=#{Jason.encode!(value)};el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return true;",
        opts
      )

  @doc "Imports backend PNG via Images; labels Lightpanda text-layout or Chromium CSS pixels."
  def screenshot(browser, opts \\ []) do
    with {:ok, %{"data" => data}} <- request(browser, %{op: "screenshot"}, opts),
         {:ok, bytes} <- Base.decode64(data),
         {:ok, "image/png", _, _} <- Vega.Images.dimensions(bytes) do
      with {:ok, image} <- Vega.Images.import_bytes(bytes),
           do:
             {:ok,
              %{
                image: image,
                rendering:
                  if(Map.get(browser, :backend) == :chromium,
                    do: :css_pixels,
                    else: :lightpanda_text_layout
                  )
              }}
    else
      {:ok, _} -> {:error, :unsupported_screenshot_no_png}
      {:error, _} = error -> error
      _ -> {:error, :invalid_screenshot_png}
    end
  end

  @doc "Bounded generic CDP. browser_scope: true sends without target sessionId."
  def command(browser, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params),
      do:
        request(
          browser,
          %{
            op: "command",
            method: method,
            params: params,
            browser_scope: Keyword.get(opts, :browser_scope, false)
          },
          opts
        )

  @doc "Sets CSS viewport dimensions (1..2000), device scale 1; Chromium supported."
  def viewport(browser, width, height, opts \\ []) do
    if is_integer(width) and width in 1..2000 and is_integer(height) and height in 1..2000,
      do:
        command(
          browser,
          "Emulation.setDeviceMetricsOverride",
          %{
            width: width,
            height: height,
            deviceScaleFactor: 1,
            mobile: Keyword.get(opts, :mobile, false)
          },
          opts
        ),
      else: {:error, :invalid_viewport}
  end

  @doc "CDP keyDown/keyUp for named keys or one character; modifiers CDP bitmask."
  def press(browser, key, opts \\ []) when is_binary(key) do
    if key in [
         "Enter",
         "Tab",
         "Escape",
         "Backspace",
         "Delete",
         "ArrowLeft",
         "ArrowRight",
         "ArrowUp",
         "ArrowDown"
       ] or String.length(key) == 1,
       do:
         request(
           browser,
           %{op: "press", key: key, modifiers: Keyword.get(opts, :modifiers, 0)},
           opts
         ),
       else: {:error, :invalid_key}
  end

  defp element_action(browser, selector, action, opts) when is_binary(selector),
    do:
      evaluate(
        browser,
        "(() => {const el=document.querySelector(#{Jason.encode!(selector)});if(!el) throw Error('selector not found');#{action}})()",
        opts
      )

  defp request(browser, body, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    if not is_integer(timeout) or timeout not in 1..25000 or
         byte_size(Jason.encode!(body)) > 100_000 do
      {:error, :invalid_timeout_or_request_too_large}
    else
      with {:ok, %{status: state}} when state in [:starting, :running] <- status(browser),
           {:ok, response} <-
             Req.post("http://127.0.0.1:#{browser.port}/",
               json: body,
               headers: [{"authorization", "Bearer " <> browser.token}],
               retry: false,
               redirect: false,
               receive_timeout: timeout,
               connect_options: [timeout: timeout]
             ) do
        case response.body do
          %{"ok" => true, "result" => result} -> {:ok, result}
          %{"ok" => false, "error" => error} -> {:error, error}
          _ -> {:error, :invalid_bridge_response}
        end
      else
        {:ok, _} -> {:error, :session_not_running}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _ -> {:error, :invalid_session}
  end

  defp await_ready(_dir, _task, 0), do: {:error, :browser_start_timeout}

  defp await_ready(dir, task, n) do
    case resume(dir) do
      {:ok, _} = result ->
        result

      _ ->
        case Vega.Tasks.status(task) do
          {:ok, %{status: state}} when state in [:starting, :running] ->
            Process.sleep(50)
            await_ready(dir, task, n - 1)

          _ ->
            {:error, %{kind: :browser_start_failed, task_dir: task.dir}}
        end
    end
  end

  defp quote_sh(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
