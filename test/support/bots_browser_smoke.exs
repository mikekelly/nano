# Run in its own OS VM: MIX_ENV=test mix run --no-start test/support/bots_browser_smoke.exs
# No model calls: production Runtime is stopped before seeding and replaced with a
# deterministic decision/adapter. All state is under a unique temporary directory.
defmodule Nano.Bots.BrowserAdapter do
  def ensure(bot, session, _), do: {:ok, "browser-#{bot.id}-#{session.id}"}
  def deliver(_, _), do: :ok
  def notify(_, _), do: :ok
  def status(_), do: %{status: :idle}
end

root = System.fetch_env!("BOTS_BROWSER_DIR")
File.mkdir_p!(root)

for {key, leaf} <- [state_dir: "state", log_dir: "logs", spill_dir: "spill", image_dir: "images"],
    do: Application.put_env(:nano, key, Path.join(root, leaf))

config = Application.fetch_env!(:nano, NanoWeb.Endpoint)

Application.put_env(
  :nano,
  NanoWeb.Endpoint,
  Keyword.merge(config, server: true, http: [ip: {127, 0, 0, 1}, port: 0])
)

{:ok, _} = Application.ensure_all_started(:nano)
:ok = Supervisor.terminate_child(Nano.Supervisor, Nano.Bots.Runtime)

{:ok, _} =
  Nano.Bots.Runtime.start_link(
    adapter: Nano.Bots.BrowserAdapter,
    router_opts: [
      evaluate: fn _, questions, _ ->
        {:ok, %{answers: Map.new(questions, fn {id, _} -> {id, %{noul: 0.0}} end)}}
      end
    ],
    state_dir: Path.join(root, "runtime")
  )

{:ok, {_, port}} = NanoWeb.Endpoint.server_info(:http)

File.write!(
  Path.join(root, "endpoint.json"),
  Jason.encode!(%{url: "http://127.0.0.1:#{port}", root: root})
)

IO.puts("BOTS_BROWSER_READY #{port}")
Process.sleep(:infinity)
