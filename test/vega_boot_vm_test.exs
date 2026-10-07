defmodule Vega.BootVMTest do
  use ExUnit.Case, async: true

  test "a fresh BEAM eagerly starts capabilities with isolated durable roots" do
    root =
      Path.join(
        System.tmp_dir!(),
        "vega-boot-vm-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    env = for app <- [:nano, :phoenix], {k, v} <- Application.get_all_env(app), do: {app, k, v}
    config = Path.join(root, "env.term")
    File.write!(config, :erlang.term_to_binary(env))
    source = Path.join(root, "boot.exs")

    File.write!(source, """
    Application.load(:nano)
    for {app,k,v} <- :erlang.binary_to_term(File.read!(#{inspect(config)})), do: Application.put_env(app,k,v)
    root = #{inspect(root)}
    Application.put_env(:nano,:vega_autostart,true)
    Application.put_env(:nano,:state_dir,Path.join(root,"state"))
    Application.put_env(:nano,:log_dir,Path.join(root,"logs"))
    Application.put_env(:nano,:test_dir,root)
    Application.put_env(:nano,:vega_root,Path.join(root,"bots"))
    Application.put_env(:nano,:vega_mcp_state_dir,Path.join(root,"mcp"))
    endpoint = Application.get_env(:nano,NanoWeb.Endpoint,[]) |> Keyword.put(:server,false)
    Application.put_env(:nano,NanoWeb.Endpoint,endpoint)
    {:ok,_} = Application.ensure_all_started(:nano)
    ids = Supervisor.which_children(Nano.Supervisor) |> Enum.map(&elem(&1,0))
    for mod <- [Vega.Delegation.Supervisor,Vega.MCP.Supervisor,Vega.Bots.Server] do
      true = mod in ids
      true = is_pid(Process.whereis(mod))
    end
    {:ok,%{"bots" => []}} = Vega.Bots.snapshot()
    [] = NanoAgent.list()
    Application.stop(:nano)
    IO.puts("VEGA_BOOT_VM_OK")
    """)

    paths = Path.wildcard(Path.join([File.cwd!(), "_build", "test", "lib", "*", "ebin"]))

    {out, code} =
      System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ [source],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert code == 0, out
    assert out =~ "VEGA_BOOT_VM_OK"
  end
end
