# Each run logs to a fresh directory: agent ids can repeat between runs, and a reused id
# would otherwise read back the previous run's JSONL entries.
run = Path.join(System.tmp_dir!(), "nano-test-#{System.os_time(:nanosecond)}")
log_dir = Path.join(run, "logs")
Application.put_env(:nano, :log_dir, log_dir)
# Likewise agent state files.
Application.put_env(:nano, :state_dir, Path.join(run, "state"))
Application.put_env(:nano, :spill_dir, Path.join(run, "spill"))
ExUnit.after_suite(fn _ -> File.rm_rf(run) end)

ExUnit.start()
