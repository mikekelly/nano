# Narrow U01 launcher: never start the app until effective mutable paths are audited.
root = "/data/altair-flywheel/runs/u01-73938543"
tmp = "/tmp/altair-u01-73938543-f550094dfb48"

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
    "crash" => System.fetch_env!("ERL_CRASH_DUMP")
  })

for {key, path} <- paths do
  expanded = Path.expand(path)

  unless String.starts_with?(expanded, root <> "/") or String.starts_with?(expanded, tmp <> "/") or
           expanded == tmp,
         do: raise("unsafe path: #{key}")

  Enum.reduce(Path.split(expanded), "", fn part, acc ->
    current = Path.join(acc, part)

    case File.lstat(current) do
      {:ok, %{type: :symlink}} -> raise("symlink in #{key}")
      _ -> :ok
    end

    current
  end)
end

IO.puts("U01 effective private path audit: " <> Jason.encode!(paths))
File.mkdir_p!(Path.join(root, "runtime"))
File.write!(Path.join(root, "runtime/path-audit.json"), Jason.encode!(paths))
{:ok, _} = Application.ensure_all_started(:nano)

if "--baseline" in System.argv() do
  {old, 0} =
    System.cmd("git", [
      "show",
      "28f16500fcb2b38d4c397efda05fbbda704cb0e3:lib/nano_web/endpoint.ex"
    ])

  Code.compile_string(old)
  code = "send(:erlang.list_to_pid(#{inspect(:erlang.pid_to_list(self()))}), :baseline_executed)"
  query = URI.encode_query(%{code: code})

  for {body, type} <- [{query, "application/x-www-form-urlencoded"}, {"", "text/plain"}] do
    conn =
      Plug.Test.conn("POST", "/api/eval?" <> query, body)
      |> Plug.Conn.put_req_header("content-type", type)

    response = NanoWeb.Endpoint.call(conn, NanoWeb.Endpoint.init([]))

    executed =
      receive do
        :baseline_executed -> true
      after
        1000 -> false
      end

    IO.puts("U01 baseline #{type}: status=#{response.status}, actual_eval_effect=#{executed}")
    unless executed, do: raise("baseline did not reproduce")
  end

  System.halt(0)
end

Code.require_file("test/test_helper.exs")

ExUnit.configure(seed: 17, autorun: false)

focused =
  ~w(test/nano_web/api_guard_endpoint_test.exs test/nano_web/api_controller_test.exs test/nano_web/images_test.exs test/nano_web/safety_api_test.exs test/nano/open_router_auth_test.exs test/nano/settings_test.exs test/nano/chatgpt_test.exs test/nano/user_test.exs test/smoke_test.exs)

files = if "--full" in System.argv(), do: Path.wildcard("test/**/*_test.exs"), else: focused
Enum.each(files, &Code.require_file/1)
result = ExUnit.run()
IO.puts("U01 result: " <> inspect(result))
System.halt(if result.failures == 0, do: 0, else: 1)
