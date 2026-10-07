# Opt-in read/navigation-only live /bots QA, NOT part of mix test.
# MIX_ENV=test VEGA_BROWSER_NODE=/tmp/vega-browser-tools/node mix run --no-start priv/vega_browser_qa.exs
Application.ensure_all_started(:req)

defmodule Vega.BrowserQA do
  alias Vega.Browser, as: B
  def wait(b, expression, tries \\ 100)
  def wait(_b, expression, 0), do: raise("UI condition timed out: #{expression}")

  def wait(b, expression, tries) do
    case B.evaluate(b, expression) do
      {:ok, true} ->
        :ok

      _ ->
        Process.sleep(50)
        wait(b, expression, tries - 1)
    end
  end

  def image(b, root, name) do
    {:ok, %{image: ref, rendering: :css_pixels}} = B.screenshot(b)
    {:ok, bytes, "image/png"} = Vega.Images.fetch(ref["id"])
    path = Path.join(root, name <> ".png")
    :ok = Vega.Files.write(path, bytes)

    IO.inspect(%{
      screenshot: name,
      path: path,
      width: ref["width"],
      height: ref["height"],
      bytes: ref["bytes"]
    })
  end

  def run do
    url = System.get_env("VEGA_BROWSER_QA_URL") || "http://127.0.0.1:4000/bots"

    root =
      Path.join(
        "/tmp/vega-browser-tools/qa",
        Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    {:ok, b} =
      B.start(
        backend: :chromium,
        node: System.get_env("VEGA_BROWSER_NODE") || "/tmp/vega-browser-tools/node",
        agent: nil,
        root: Path.join(root, "session"),
        lifetime: 90_000
      )

    try do
      {:ok, _} =
        B.command(b, "Page.addScriptToEvaluateOnNewDocument", %{
          source:
            "window.qaErrors=[];window.addEventListener('error',e=>{if(window.qaErrors.length<25)window.qaErrors.push(e.message)});"
        })

      {:ok, _} = B.viewport(b, 1280, 800)
      {:ok, _} = B.navigate(b, url)

      wait(
        b,
        "!!window.botsLiveSocket?.isConnected() && document.querySelectorAll('.chat-row').length >= 1"
      )

      {:ok, true} = B.click(b, ".chat-row")
      wait(b, "!!document.querySelector('#composer')")
      image(b, root, "desktop-conversation")

      {:ok, desktop} =
        B.evaluate(
          b,
          "({rows:document.querySelectorAll('.chat-row').length, messages:document.querySelectorAll('.messages article, .message-list article').length, horizontalOverflow:document.documentElement.scrollWidth>innerWidth, timelineNodes:document.querySelectorAll('.timeline,[data-tool-call]').length, title:document.title})"
        )

      %{"horizontalOverflow" => false, "timelineNodes" => 0, "messages" => message_count} =
        desktop

      if message_count > 100, do: raise("Consumer DOM rendered more than 100 message nodes")
      IO.inspect(%{desktop: desktop})
      {:ok, true} = B.click(b, "button[aria-label='New chat']")
      wait(b, "!!document.querySelector('#recipient-query')")
      {:ok, true} = B.fill(b, "#recipient-query", "")
      wait(b, "document.querySelectorAll('#recipient-options [data-shortcut]').length >= 2")
      {:ok, true} = B.evaluate(b, "document.querySelector('#recipient-query').focus();true")
      {:ok, true} = B.press(b, "1", modifiers: 2)
      wait(b, "document.querySelectorAll('.recipient-chips .chip').length === 1")
      {:ok, true} = B.fill(b, "#recipient-query", "")
      wait(b, "document.querySelectorAll('#recipient-options [data-shortcut]').length >= 1")
      {:ok, true} = B.evaluate(b, "document.querySelector('#recipient-query').focus();true")
      {:ok, true} = B.press(b, "1", modifiers: 2)
      wait(b, "document.querySelectorAll('.recipient-chips .chip').length === 2")

      {:ok, chips} =
        B.evaluate(
          b,
          "Array.from(document.querySelectorAll('.recipient-chips .chip'),x=>x.textContent.trim())"
        )

      IO.inspect(%{keyboard_recipient_chips: chips})
      image(b, root, "desktop-two-chips")
      {:ok, _} = B.viewport(b, 390, 844, mobile: true)
      image(b, root, "mobile-two-chips")

      {:ok, mobile} =
        B.evaluate(
          b,
          "({pane:document.querySelector('.bots-app').dataset.pane,width:innerWidth,scrollWidth:document.documentElement.scrollWidth, sidebarDisplay:getComputedStyle(document.querySelector('.sidebar')).display})"
        )

      %{"pane" => "chat", "width" => 390, "scrollWidth" => 390, "sidebarDisplay" => "none"} =
        mobile

      IO.inspect(%{mobile_chat: mobile})
      {:ok, true} = B.fill(b, "#recipient-query", "")
      wait(b, "!!document.querySelector('#recipient-options')")
      {:ok, true} = B.evaluate(b, "document.querySelector('#recipient-query').focus();true")
      {:ok, true} = B.press(b, "Escape")
      wait(b, "!document.querySelector('#recipient-options')")
      {:ok, true} = B.fill(b, "#recipient-query", "QA unsaved bot")
      wait(b, "!!document.querySelector('#recipient-options')")
      {:ok, true} = B.press(b, "ArrowDown")
      {:ok, true} = B.press(b, "Enter")
      wait(b, "!!document.querySelector('#create-bot')")
      image(b, root, "mobile-create-form-unsaved")
      {:ok, true} = B.click(b, ".mobile-back")
      wait(b, "document.querySelector('.bots-app').dataset.pane==='list'")
      image(b, root, "mobile-chat-list")
      {:ok, true} = B.click(b, "button[phx-click='toggle-settings']")
      wait(b, "!!document.querySelector('#enable-notifications')")
      origin = URI.parse(url)
      origin = "#{origin.scheme}://#{origin.host}:#{origin.port}"

      {:ok, _} =
        B.command(
          b,
          "Browser.grantPermissions",
          %{origin: origin, permissions: ["notifications"]},
          browser_scope: true
        )

      {:ok, true} = B.click(b, "#enable-notifications")

      wait(
        b,
        "document.querySelector('#notification-permission').textContent.includes('enabled')"
      )

      {:ok, permission} =
        B.evaluate(
          b,
          "({permission:Notification.permission,status:document.querySelector('#notification-permission').textContent,errors:window.qaErrors})"
        )

      %{"permission" => "granted", "errors" => []} = permission
      IO.inspect(%{notification_permission_ui: permission})
      image(b, root, "mobile-notification-permission")

      IO.puts(
        "QA_COMPLETE #{root} (no chat sent; no bot/session created; no settings checkbox changed)"
      )
    after
      B.stop(b)
      Process.sleep(100)
    end
  end
end

Vega.BrowserQA.run()
