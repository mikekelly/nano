defmodule MCPOptionalServiceTest do
  use ExUnit.Case, async: true

  test "configured but unavailable MCP is never lazy-started outside its supervisor" do
    assert isolated_policy(
             "defmodule Nano.OptionalServices do\n def configured?(MCP), do: true\nend"
           ) ==
             "{{:error, :service_unavailable}, nil}"
  end

  test "standalone use still attempts lazy start when optional service module is absent" do
    # This subprocess's code path excludes Nano.OptionalServices even when the parent
    # suite has the real optional service supervisor loaded.
    assert isolated_policy("") == "{{:error, {:error, :lazy_start_attempted}}, nil}"
  end

  test "unconfigured optional service does not prohibit standalone lazy startup" do
    assert isolated_policy(
             "defmodule Nano.OptionalServices do\n def configured?(MCP), do: false\nend"
           ) ==
             "{{:error, {:error, :lazy_start_attempted}}, nil}"
  end

  test "older optional service module without configured?/1 remains standalone-compatible" do
    assert isolated_policy("defmodule Nano.OptionalServices do\n def older_api, do: :ok\nend") ==
             "{{:error, {:error, :lazy_start_attempted}}, nil}"
  end

  defp isolated_policy(optional_module) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "deneb-mcp-policy-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(dir)

    try do
      # Only copy MCP itself, not the project's ebin directory: this checks the
      # module-absent case even in an integrated checkout. A fake config loader
      # fails before any state directory is created. No /data writes, app starts,
      # node-wide environment changes or live-module replacement occur.
      File.cp!(:code.which(MCP) |> List.to_string(), Path.join(dir, "Elixir.MCP.beam"))

      script = """
      defmodule MCP.Config do
        def load(_), do: {:error, :lazy_start_attempted}
      end
      #{optional_module}
      IO.inspect({MCP.servers(), Process.whereis(MCP)})
      """

      {output, status} =
        System.cmd(
          System.find_executable("elixir"),
          ["--erl", "+S 2:2", "-pa", dir, "-e", script],
          stderr_to_stdout: true,
          env: [{"ERL_CRASH_DUMP", Path.join(dir, "erl_crash.dump")}]
        )

      assert status == 0, output
      String.trim(output)
    after
      File.rm_rf(dir)
    end
  end
end
