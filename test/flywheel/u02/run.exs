# Run with MIX_ENV=test mix run --no-start test/flywheel/u02/run.exs [--full].
# The caller must provide private build/deps/tool caches and TMPDIR. No store overrides:
# this audit exercises actual runtime configuration before any application side effects.
root = Application.fetch_env!(:nano, :test_dir)

paths =
  for key <- [:image_dir, :web_cache_dir, :safety_dir, :state_dir, :log_dir, :spill_dir],
      into: %{},
      do: {Atom.to_string(key), Application.fetch_env!(:nano, key)}

paths =
  Map.merge(paths, %{
    "test" => root,
    "tmp" => System.tmp_dir!(),
    "crash" => System.fetch_env!("ERL_CRASH_DUMP"),
    "web_env" => System.fetch_env!("NANO_WEB_CACHE_DIR"),
    "safety_env" => System.fetch_env!("NANO_SAFETY_DIR")
  })

for {key, path} <- paths do
  unless Path.expand(path) == root or String.starts_with?(Path.expand(path), root <> "/"),
    do: raise("unsafe runtime path: #{key}")
end

private = System.fetch_env!("NANO_TEST_PRIVATE_ROOT") |> Path.expand()

external = %{
  "build" => Mix.Project.build_path(),
  "deps" => Mix.Project.deps_path(),
  "home" => System.fetch_env!("HOME"),
  "mix_home" => System.fetch_env!("MIX_HOME"),
  "hex_home" => System.fetch_env!("HEX_HOME")
}

for {key, path} <- external do
  unless String.starts_with?(Path.expand(path), private <> "/"),
    do: raise("unsafe tool path: #{key}")
end

for {key, path} <- Map.merge(paths, external) do
  Enum.reduce(Path.split(Path.expand(path)), "", fn part, acc ->
    current = if acc == "" and part == "/", do: "/", else: Path.join(acc, part)

    case File.lstat(current) do
      {:ok, %{type: :symlink}} -> raise("symlink in #{key}")
      _ -> :ok
    end

    current
  end)
end

report = System.fetch_env!("NANO_TEST_PATH_REPORT")
File.write!(report, Jason.encode!(Map.merge(paths, external)))
IO.puts("U02 effective private path audit: " <> Jason.encode!(Map.merge(paths, external)))
{:ok, _} = Application.ensure_all_started(:nano)
Code.require_file("test/test_helper.exs")
ExUnit.configure(seed: 17, autorun: false)

files =
  if "--full" in System.argv(),
    do: Path.wildcard("test/**/*_test.exs"),
    else: [
      "test/tools_test.exs",
      "test/web_test.exs",
      "test/nano/images_test.exs",
      "test/nano/safety_test.exs",
      "test/flywheel/u02/isolation_test.exs"
    ]

Enum.each(files, &Code.require_file/1)
result = ExUnit.run()
IO.puts("U02 result: " <> inspect(result))
System.halt(if result.failures == 0, do: 0, else: 1)
