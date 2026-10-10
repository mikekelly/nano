Code.require_file("test/flywheel/u07/audit.exs")
{:ok, _} = Application.ensure_all_started(:nano)
Code.require_file("test/test_helper.exs")
ExUnit.configure(seed: 17, autorun: false)

files =
  if "--full" in System.argv(),
    do: Path.wildcard("test/**/*_test.exs"),
    else: [
      "test/nano/chatgpt_test.exs",
      "test/nano/settings_test.exs",
      "test/nano/safety_test.exs",
      "test/flywheel/u07/intent_test.exs"
    ]

Enum.each(files, &Code.require_file/1)
result = ExUnit.run()
IO.puts("U07 result: " <> inspect(result))
System.halt(if result.failures == 0, do: 0, else: 1)
