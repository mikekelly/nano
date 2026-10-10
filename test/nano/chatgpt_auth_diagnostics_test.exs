defmodule Nano.AuthDiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @modules [Nano.ChatGPT.Auth, Nano.Settings, Nano.OpenRouter.Auth]
  @secret "U04-dummy-credential-9c8e74"

  defp start_server(module) do
    {:ok, pid} = GenServer.start(module, nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  test "all OTP status payloads, envelopes, log and reasons are secret-free" do
    for module <- @modules,
        message <- [
          {:refresh, @secret},
          {:put, @secret, @secret},
          {:"$gen_call", {self(), @secret}, {:put, @secret, @secret, @secret}}
        ] do
      status = %{
        state: %{@secret => @secret, :tokens => %{"access_token" => @secret}, :login => @secret},
        message: message,
        reason: {:badmatch, @secret},
        log: [{:in, message}],
        future_payload: @secret
      }

      result = module.format_status(status)
      refute inspect(result) =~ @secret
      assert result.reason == :badmatch
      assert Map.keys(result) == Map.keys(status)
      refute inspect(module.format_status(%{reason: {@secret, @secret}})) =~ @secret
      assert module.format_status(%{}) == %{}
      assert module.format_status(%{state: nil, log: []}) == %{state: :redacted, log: :redacted}

      for payload <- [:tokens, :login, :reason, :message, :log] do
        dummy = @secret <> Atom.to_string(payload)
        refute inspect(module.format_status(%{payload => dummy})) =~ dummy
      end
    end
  end

  test "termination with secret reason and queued refresh/gen-call envelopes" do
    for module <- @modules do
      pid = start_server(module)
      :sys.replace_state(pid, fn _ -> %{@secret => @secret} end)
      :sys.suspend(pid)
      send(pid, {:refresh, @secret})
      send(pid, {:"$gen_call", {self(), make_ref()}, {:put, @secret, @secret}})
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          :sys.terminate(pid, {@secret, @secret})
          assert_receive {:DOWN, ^ref, :process, ^pid, :redacted}
        end)

      refute log =~ @secret
    end
  end

  test "real isolated GenServers redact sys status and actual termination logger" do
    # Anonymous servers use the production callbacks, not the supervised node fixtures.
    # No credential APIs or durable writes are invoked after replacing this dummy state.
    for module <- @modules do
      pid = start_server(module)
      :sys.replace_state(pid, fn _ -> %{@secret => @secret} end)
      refute inspect(:sys.get_status(pid)) =~ @secret
      :sys.log(pid, true)
      assert {:error, :unknown_call} = GenServer.call(pid, {:dummy, @secret})
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          # A malformed callback state reaches the actual production handle_call path.
          :sys.replace_state(pid, fn _ -> @secret end)

          try do
            case module do
              Nano.ChatGPT.Auth -> GenServer.call(pid, {:refresh, @secret})
              Nano.Settings -> GenServer.call(pid, {:put, @secret, @secret})
              Nano.OpenRouter.Auth -> GenServer.call(pid, {:put, @secret, @secret, @secret})
            end
          catch
            :exit, _ -> :ok
          end

          assert_receive {:DOWN, ^ref, :process, ^pid, _}
        end)

      refute log =~ @secret
      assert log =~ "terminating"
      if module == Nano.Settings, do: assert(log =~ "badmap")
    end
  end
end
