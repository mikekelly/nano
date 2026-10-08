# MIX_ENV=test mix run test/support/bots_browser_server.exs
# Disposable HTTP instance for test/bots_browser_smoke.mjs. Never starts paid agents.
if Mix.env() != :test, do: raise("Browser smoke server requires MIX_ENV=test")

defmodule Bots.BrowserSmoke.Runtime do
  def dispatch(bot, _session, context, _opts) do
    Bots.post(context.token, "**#{bot["name"]}** heard you.\n\n```text\nsafe code example\n```",
      server: context.server
    )
  end

  def stop(_bot, _session, _opts), do: :ok
end

defmodule Bots.BrowserSmoke.Router do
  def select(bots, _session, message, _opts) do
    {:ok, if(message["kind"] == "human", do: Enum.map(bots, & &1["id"]), else: [])}
  end
end

{:ok, _} = Bots.start_link(runtime: Bots.BrowserSmoke.Runtime, router: Bots.BrowserSmoke.Router)

{:ok, server} =
  Bandit.start_link(plug: NanoWeb.Endpoint, ip: :loopback, port: 0, startup_log: false)

{:ok, {_ip, port}} = ThousandIsland.listener_info(server)
IO.puts("BOTS_URL=http://127.0.0.1:#{port}")
Process.sleep(:infinity)
