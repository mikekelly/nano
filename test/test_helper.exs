# config/runtime.exs gave this run a fresh directory, where the app writes its logs, state,
# spills and images. Tests put their own files there too (Application.fetch_env!(:nano,
# :test_dir)): other suites may be running at once, in this checkout or another.
run = Application.fetch_env!(:nano, :test_dir)
File.mkdir_p!(run)
# A crash dump of this VM goes there as well: the image points ERL_CRASH_DUMP at /data.
System.put_env("ERL_CRASH_DUMP", Path.join(run, "erl_crash.dump"))
ExUnit.after_suite(fn _ -> File.rm_rf(run) end)

ExUnit.start()
