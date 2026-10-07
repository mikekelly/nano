defmodule Vega.MCPCredentialLogHandler do
  @moduledoc false
  def adding_handler(config), do: {:ok, config}
  def removing_handler(_), do: :ok
  def log(event, %{config: %{owner: owner}}), do: send(owner, {:credential_log_report, event})
end

defmodule Vega.MCPCredentialTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Vega.MCP

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vega-mcp-redaction-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    saved = Application.get_env(:nano, :vega_mcp_state_dir)
    Application.put_env(:nano, :vega_mcp_state_dir, dir)
    start_supervised!({Vega.MCP.Supervisor, []})
    name = "redact-#{System.unique_integer([:positive])}"

    token =
      "VEGA_FAKE_SECRET_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    config = %{
      "command" => "python3",
      "args" => [Path.expand("vega_mcp_fixture.py", __DIR__), token],
      "env" => %{"VEGA_MCP_FAKE_SECRET" => token},
      "headers" => %{"authorization" => "Bearer " <> token, "x-api-key" => token}
    }

    assert {:ok, _} = MCP.connect(name, config)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:nano, :vega_mcp_state_dir, saved),
        else: Application.delete_env(:nano, :vega_mcp_state_dir)

      File.rm_rf!(dir)
    end)

    %{name: name, token: token, config: config, dir: dir}
  end

  defp reports do
    receive do
      {:credential_log_report, event} -> [event | reports()]
    after
      30 -> []
    end
  end

  defp observe_otp_reports do
    # Logger's default primary translator drops SASL Supervisor reports before
    # handlers. Enable them only in this isolated test VM and restore exact filters.
    filters = :logger.get_primary_config().filters

    enabled =
      Enum.map(filters, fn
        {:logger_translator, {fun, options}} ->
          {:logger_translator, {fun, Map.put(options, :sasl, true)}}

        pair ->
          pair
      end)

    :ok = :logger.set_primary_config(:filters, enabled)
    on_exit(fn -> :logger.set_primary_config(:filters, filters) end)
    id = :vega_mcp_credential_test_report_handler

    :ok =
      :logger.add_handler(id, Vega.MCPCredentialLogHandler, %{
        level: :all,
        filter_default: :log,
        config: %{owner: self()}
      })

    on_exit(fn -> :logger.remove_handler(id) end)
  end

  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(20)
            eventually(fun, n - 1)
          )
      )

  test "child specification/start arguments and formatted statuses never contain credentials",
       ctx do
    [{pid, _}] = Registry.lookup(Vega.MCP.Registry, ctx.name)
    # Raw DynamicSupervisor status includes every restart MFA and start argument.
    refute inspect(:sys.get_state(Vega.MCP.Connections), limit: :infinity) =~ ctx.token

    for service <- [pid, Vega.MCP.State, Vega.MCP.Config] do
      refute inspect(:sys.get_status(service), limit: :infinity) =~ ctx.token
    end

    # trusted root can explicitly fetch it
    assert {:ok, _} = Vega.MCP.Config.get(ctx.name)
    assert :ok = MCP.watch(ctx.name, ctx.name <> "-offline")
    refute File.read!(Path.join(ctx.dir, "subscriptions.json")) =~ ctx.token
    # Redact state, last message, debug log and exit reason independently.
    fake = %{
      state: :sys.get_state(pid),
      message: {:put, ctx.config},
      reason: {:fake_crash, ctx.token},
      log: [ctx.config]
    }

    formatted = Vega.MCP.Connection.format_status(fake)
    refute inspect(formatted, limit: :infinity) =~ ctx.token
    assert formatted.message == :redacted
    assert formatted.reason == :redacted
    assert formatted.log == []
  end

  test "abnormal GenServer and Supervisor crash reports sanitize reasons and retained credentials",
       ctx do
    observe_otp_reports()
    [{old, _}] = Registry.lookup(Vega.MCP.Registry, ctx.name)
    :ok = :sys.log(old, true)
    assert {:ok, _} = MCP.call_tool(ctx.name, "echo", %{"secret_argument" => ctx.token})
    send(old, {:secret_debug_message, ctx.token})

    logs =
      capture_log(fn ->
        # No actual key: simulated accidental exception/stop message embeds only the
        # isolated random fake credential. Callback terminates with a sanitized reason.
        try do
          GenServer.stop(old, {:simulated_credential_crash, ctx.token})
        catch
          :exit, _ -> :ok
        end

        eventually(fn ->
          case Registry.lookup(Vega.MCP.Registry, ctx.name) do
            [{pid, _}] -> pid != old
            _ -> false
          end
        end)

        assert {:ok, _} = MCP.connect(ctx.name, ctx.config)
        assert {:ok, _} = MCP.tools(ctx.name)
      end)

    captured = inspect(reports(), limit: :infinity)
    assert captured =~ "child_terminated"
    assert captured =~ "mcp_service_failure"
    refute captured =~ ctx.token
    assert logs =~ "redacted"
    refute logs =~ ctx.token
    refute logs =~ "secret_argument"
    refute logs =~ "secret_debug_message"
    # Restart specs themselves are credential-free; the new worker retrieved the
    # configuration from memory and still ran the subprocess with its configured env.
    refute inspect(:sys.get_state(Vega.MCP.Connections), limit: :infinity) =~ ctx.token
  end

  test "config and subscription-state service crashes cannot dump credential-bearing messages",
       ctx do
    observe_otp_reports()

    for {service, kind} <- [{Vega.MCP.Config, :config}, {Vega.MCP.State, :state}] do
      old = Process.whereis(service)

      logs =
        capture_log(fn ->
          :ok = :sys.log(old, true)
          send(old, {:secret_message, ctx.token})

          try do
            GenServer.stop(old, {:simulated_crash, ctx.token})
          catch
            :exit, _ -> :ok
          end

          eventually(fn ->
            new = Process.whereis(service)
            is_pid(new) and new != old
          end)
        end)

      captured = inspect(reports(), limit: :infinity)
      assert captured =~ "child_terminated"
      assert captured =~ "mcp_service_failure"
      assert captured =~ Atom.to_string(kind)
      refute captured =~ ctx.token
      assert logs =~ "redacted"
      refute logs =~ ctx.token
    end

    # Credentials aren't persisted: an explicit connect rehydrates an empty store.
    assert {:ok, _} = MCP.connect(ctx.name, ctx.config)
    [{old_worker, _}] = Registry.lookup(Vega.MCP.Registry, ctx.name)
    Process.exit(old_worker, :kill)

    eventually(fn ->
      case Registry.lookup(Vega.MCP.Registry, ctx.name) do
        [{pid, _}] -> pid != old_worker
        _ -> false
      end
    end)

    assert {:ok, _} = MCP.connect(ctx.name, ctx.config)
  end

  test "incidental credential echoes are scrubbed recursively before errors/events", ctx do
    reason =
      {:remote,
       %{
         "message" => "bad bearer " <> ctx.token,
         "nested" => [ctx.config["headers"]["authorization"]]
       }}

    safe = Vega.MCP.Redact.value(reason, ctx.config)
    refute inspect(safe, limit: :infinity) =~ ctx.token
    assert inspect(safe) =~ "REDACTED"
    assert {:error, %{"message" => message}} = MCP.call_tool(ctx.name, "credential_error")
    refute message =~ ctx.token
    assert message =~ "REDACTED"
    agent = ctx.name <> "-watcher"
    :yes = Nano.Names.register_name({:agent, agent}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, agent}) end)
    assert :ok = MCP.watch(ctx.name, agent)
    assert {:ok, _} = MCP.call_tool(ctx.name, "credential_log")

    assert_receive {:"$gen_cast",
                    {:notify, %{method: "notifications/message", params: %{"data" => data}}}},
                   2000

    refute data =~ ctx.token
    assert data =~ "REDACTED"
  end

  test "transport/spawn exception classifications do not interpolate env/header values", ctx do
    # Invalid cwd must fail with a class, not Port.open's rendered argument list
    # (which would include the env list and argv fake credential).
    second = ctx.name <> "-bad-launch"
    config = Map.put(ctx.config, "cwd", 42)
    assert {:error, {:disconnected, {:spawn_failed, ArgumentError}}} = MCP.connect(second, config)

    assert {:error, {:http_transport, _class}} =
             Vega.MCP.HTTP.run(
               self(),
               make_ref(),
               %{
                 "url" => "http://127.0.0.1:1",
                 "headers" => %{"authorization" => ctx.token <> "\r\n"}
               },
               nil,
               "2025-11-25",
               :post,
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
             )
  end
end
