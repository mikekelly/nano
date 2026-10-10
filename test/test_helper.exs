# config/runtime.exs gave this run a fresh directory, where the app writes its logs, state
# and spills. Tests put their own files there too (Application.fetch_env!(:nano,
# :test_dir)): other suites may be running at once, in this checkout or another.
run = Application.fetch_env!(:nano, :test_dir)
File.mkdir_p!(run)
# A crash dump of this VM goes there as well: the image points ERL_CRASH_DUMP at /data.
System.put_env("ERL_CRASH_DUMP", Path.join(run, "erl_crash.dump"))
ExUnit.after_suite(fn _ -> File.rm_rf(run) end)

# U07: explicit provisioning belongs to this disposable fixture, never production boot.
for key <- [:state_dir, :safety_dir, :log_dir, :spill_dir, :image_dir, :web_cache_dir] do
  path = Application.fetch_env!(:nano, key) |> Path.expand()
  unless String.starts_with?(path, Path.expand(run) <> "/"), do: raise("unsafe test path: #{key}")
end

:ok = Nano.Safety.provision_new_credentials(:new_installation)

# The node's settings start at their defaults, in that directory too. Tests reach providers
# only through scripted fakes (test/support), so their addresses default to a port that
# refuses connections, and OpenRouter has a key that is not one.
for {key, value} <- [
      openrouter_api_key: "test-key",
      openrouter_base_url: "http://127.0.0.1:1/unset",
      chatgpt_base_url: "http://127.0.0.1:1/unset",
      chatgpt_auth_url: "http://127.0.0.1:1/unset"
    ],
    do: :ok = Nano.Settings.put(key, value)

ExUnit.start()
