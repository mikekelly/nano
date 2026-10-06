# Each run logs to a fresh directory: agent ids can repeat between runs, and a reused id
# would otherwise read back the previous run's JSONL entries.
log_dir = Path.join(System.tmp_dir!(), "nano-test-logs-#{System.os_time(:nanosecond)}")
Application.put_env(:nano, :log_dir, log_dir)
ExUnit.after_suite(fn _ -> File.rm_rf(log_dir) end)

ExUnit.start()
