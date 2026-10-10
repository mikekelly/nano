# Narrow U03 launcher: never start the app until effective mutable paths are audited.
root = "/data/altair-flywheel/runs/u03-468326d6"
tmp = "/tmp/altair-u03-468326d6-bfb8fa1347cc"

vm =
  Path.join([root, "runtime", "vm-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)])

System.put_env("NANO_WEB_CACHE_DIR", Path.join(vm, "web"))
System.put_env("NANO_SAFETY_DIR", Path.join(vm, "safety"))
System.put_env("ERL_CRASH_DUMP", Path.join(vm, "crash.dump"))

for key <- [:image_dir, :state_dir, :log_dir, :spill_dir] do
  Application.put_env(:nano, key, Path.join(vm, Atom.to_string(key)))
end

Application.put_env(:nano, :test_dir, Path.join(vm, "tests"))
Application.put_env(:nano, :api_public_port, 4000)

Application.put_env(:nano, :api_trusted_origins, [
  "http://localhost:4000",
  "http://127.0.0.1:4000",
  "http://[::1]:4000"
])

Application.put_env(:nano, :openrouter_callback_url, "http://localhost:4000/openrouter/callback")

paths =
  for key <- [:image_dir, :state_dir, :log_dir, :spill_dir, :test_dir],
      into: %{},
      do: {Atom.to_string(key), Application.fetch_env!(:nano, key)}

paths =
  Map.merge(paths, %{
    "web" => System.fetch_env!("NANO_WEB_CACHE_DIR"),
    "safety" => System.fetch_env!("NANO_SAFETY_DIR"),
    "tmp" => System.tmp_dir!(),
    "crash" => System.fetch_env!("ERL_CRASH_DUMP"),
    "build" => Mix.Project.build_path(),
    "deps" => Mix.Project.deps_path(),
    "home" => System.fetch_env!("HOME"),
    "mix_home" => System.fetch_env!("MIX_HOME"),
    "hex_home" => System.fetch_env!("HEX_HOME")
  })

for {key, path} <- paths do
  expanded = Path.expand(path)

  unless String.starts_with?(expanded, root <> "/") or String.starts_with?(expanded, tmp <> "/") or
           expanded == tmp,
         do: raise("unsafe path: #{key}")

  Enum.reduce(Path.split(expanded), "", fn part, acc ->
    current = if acc == "" and part == "/", do: "/", else: Path.join(acc, part)

    case File.lstat(current) do
      {:ok, %{type: :symlink}} -> raise("symlink in #{key}")
      _ -> :ok
    end

    current
  end)
end

IO.puts("U03 effective private path audit: " <> Jason.encode!(paths))
File.mkdir_p!(Path.join(root, "runtime"))
File.write!(Path.join(root, "runtime/path-audit.json"), Jason.encode!(paths))
{:ok, _} = Application.ensure_all_started(:nano)

Code.require_file("test/test_helper.exs")
ExUnit.configure(seed: 17, autorun: false, trace: "--full" not in System.argv())

files =
  if "--full" in System.argv(),
    do: Path.wildcard("test/**/*_test.exs"),
    else: Path.wildcard("test/flywheel/**/*_test.exs")

Enum.each(files, &Code.require_file/1)
result = ExUnit.run()
IO.puts("U03 result: " <> inspect(result))
System.halt(if result.failures == 0, do: 0, else: 1)
