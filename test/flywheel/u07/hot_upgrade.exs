Code.require_file("test/flywheel/u07/audit.exs")
base = "1e167d4cf0a2d8305b904d0f68f5d2975ddee425"
state = Application.fetch_env!(:nano, :state_dir)
File.mkdir_p!(state)

fixture = %{
  "access_token" => "u07-fake-access",
  "refresh_token" => "u07-fake-refresh",
  "account_id" => "u07-fake-account",
  "expires_at" => System.system_time(:second) + 3600
}

settings = %{"openrouter_api_key" => "u07-fake-key", "eval_timeout_ms" => 30000}
File.write!(Path.join(state, "chatgpt_auth.json"), Jason.encode!(fixture))
File.write!(Path.join(state, "settings.json"), Jason.encode!(settings))
# Load old owners only into this disposable VM, before their supervision starts.
for path <- ["lib/nano/chatgpt/auth.ex", "lib/nano/settings.ex"] do
  {source, 0} = System.cmd("git", ["show", base <> ":" <> path])
  Code.compile_string(source, path)
end

{:ok, _} = Application.ensure_all_started(:nano)
auth = Process.whereis(Nano.ChatGPT.Auth)
settings_pid = Process.whereis(Nano.Settings)
true = Nano.ChatGPT.Auth.status().status == :connected
:ok = :sys.suspend(auth)
:ok = :sys.suspend(settings_pid)
# Production maintenance migration with both old publishers quiesced.
:ok = Nano.Safety.reconcile_legacy_credentials(:legacy_installation)
for path <- ["lib/nano/chatgpt/auth.ex", "lib/nano/settings.ex"], do: Code.compile_file(path)
:ok = :sys.change_code(auth, Nano.ChatGPT.Auth, :legacy, nil)
:ok = :sys.change_code(settings_pid, Nano.Settings, :legacy, nil)
:ok = :sys.resume(settings_pid)
:ok = :sys.resume(auth)
true = Process.whereis(Nano.ChatGPT.Auth) == auth
true = Process.whereis(Nano.Settings) == settings_pid
{:ok, %{access_token: "u07-fake-access"}} = Nano.ChatGPT.Auth.token()
true = Nano.Settings.get(:openrouter_api_key) == "u07-fake-key"
true = Nano.ChatGPT.Auth.status().error == nil
:ok = Nano.ChatGPT.Auth.logout()
:ok = Nano.Settings.delete(:openrouter_api_key)
# Forward mutation -> compatible owner restart; retain authority/tombstones.
Supervisor.terminate_child(Nano.Supervisor, Nano.ChatGPT.Auth)
{:ok, _} = Supervisor.restart_child(Nano.Supervisor, Nano.ChatGPT.Auth)
{:error, _} = Nano.ChatGPT.Auth.token()
:ok = Nano.Safety.reconcile_credentials()
{:ok, %{}, nil} = Nano.Safety.credential_read("chatgpt_auth.json")
{:ok, values, _} = Nano.Safety.credential_read("settings.json")
false = Map.has_key?(values, "openrouter_api_key")

IO.puts(
  "U07 old-owner suspended migration -> hot upgrade without refresh/logout -> forward invalidation -> compatible restart/restoration passed"
)

System.halt(0)
