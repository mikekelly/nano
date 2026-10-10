# Disposable VM only: mix run --no-start test/flywheel/u04/crash_boundary.exs
ExUnit.start(seed: 17)

defmodule Nano.U04BoundaryHandler do
  def adding_handler(config), do: {:ok, config}
  def log(event, config), do: send(config.owner, {:u04_event, event})
end

defmodule Nano.U04CrashBoundaryTest do
  use ExUnit.Case, async: false
  @modules [Nano.Settings, Nano.ChatGPT.Auth, Nano.OpenRouter.Auth]
  @secret "U04-SASL-QUEUED-DUMMY-31a9"

  defp events do
    receive do
      {:u04_event, event} -> [event | events()]
    after
      100 -> []
    end
  end

  defp crash_message(Nano.Settings), do: {:put, @secret, @secret}
  defp crash_message(Nano.ChatGPT.Auth), do: {:refresh, @secret}
  defp crash_message(Nano.OpenRouter.Auth), do: {:put, @secret, @secret, @secret}
  defp failure_class(Nano.OpenRouter.Auth), do: :function_clause
  defp failure_class(_), do: :badmap

  setup_all do
    root = System.fetch_env!("U04_TMP_ROOT")

    for key <- [
          :test_dir,
          :state_dir,
          :log_dir,
          :spill_dir,
          :image_dir,
          :web_cache_dir,
          :safety_dir
        ] do
      path = Application.fetch_env!(:nano, key)
      assert String.starts_with?(Path.expand(path), root <> "/")
      IO.puts("#{key}=#{path}")
    end

    primary = :logger.get_primary_config()
    old = List.keyfind(primary.filters, :logger_translator, 0)
    :logger.remove_primary_filter(:logger_translator)

    :ok =
      :logger.add_primary_filter(
        :logger_translator,
        {&Logger.Utils.translator/2,
         %{otp: true, sasl: true, translators: [{Logger.Translator, :translate}]}}
      )

    on_exit(fn ->
      :logger.remove_primary_filter(:logger_translator)
      if old, do: :logger.add_primary_filter(:logger_translator, elem(old, 1))
    end)

    :ok
  end

  test "ordinary queued crash is safe at unlimited and finite depth, native formatter and permanent recovery" do
    state_dir = Application.fetch_env!(:nano, :state_dir)
    File.mkdir_p!(state_dir)
    settings = Jason.encode!(%{"U04_DUMMY_KEY" => @secret})

    tokens =
      Jason.encode!(%{
        "access_token" => @secret,
        "refresh_token" => @secret,
        "account_id" => "dummy-account",
        "expires_at" => System.system_time(:second) + 7200
      })

    File.write!(Path.join(state_dir, "settings.json"), settings)
    File.write!(Path.join(state_dir, "chatgpt_auth.json"), tokens)

    for module <- @modules,
        do: assert(Map.get(Supervisor.child_spec(module, []), :restart, :permanent) == :permanent)

    children =
      for module <- @modules do
        spec = Supervisor.child_spec(module, [])
        %{spec | start: {Nano.Application, :start_retrying, [spec.start]}}
      end

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 20)
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)

    for module <- @modules do
      {:ok, effective} = :supervisor.get_childspec(supervisor, module)
      assert effective.restart == :permanent
    end

    :ok =
      :logger.add_handler(:u04_boundary, Nano.U04BoundaryHandler, %{
        level: :all,
        filter_default: :log,
        owner: self()
      })

    on_exit(fn -> :logger.remove_handler(:u04_boundary) end)

    for depth <- [:unlimited, 20], module <- @modules do
      Application.put_env(:kernel, :error_logger_format_depth, depth)
      pid = Process.whereis(module)
      assert is_pid(pid)
      :sys.replace_state(pid, fn _ -> @secret end)
      :sys.suspend(pid)
      send(pid, {:"$gen_call", {self(), make_ref()}, crash_message(module)})
      send(pid, {:refresh, @secret})
      send(pid, {:"$gen_call", {self(), make_ref()}, {:put, @secret, @secret}})
      ref = Process.monitor(pid)
      :sys.resume(pid)
      expected = {:shutdown, {:credential_diagnostic, failure_class(module)}}
      assert_receive {:DOWN, ^ref, :process, ^pid, ^expected}, 1000
      wait_restart(module, pid)
      captured = events()
      refute inspect(captured, limit: :infinity, printable_limit: :infinity) =~ @secret

      reports =
        for %{msg: {:report, %{label: {:gen_server, :terminate}} = report}} <- captured,
            do: report

      assert reports != []

      for report <- reports do
        assert report.log == []

        for single <- [false, true] do
          formatted =
            :gen_server.format_log(report, %{single_line: single}) |> IO.iodata_to_binary()

          refute formatted =~ @secret
          assert formatted =~ Atom.to_string(failure_class(module))
          assert formatted =~ inspect(module)
          assert formatted =~ "handle_call"
        end
      end

      assert File.read!(Path.join(state_dir, "settings.json")) == settings
      assert File.read!(Path.join(state_dir, "chatgpt_auth.json")) == tokens
      assert Nano.Settings.get("U04_DUMMY_KEY") == @secret
      assert :sys.get_state(Nano.ChatGPT.Auth).tokens["access_token"] == @secret
      assert :sys.get_state(Nano.OpenRouter.Auth) == %{}
      root = System.fetch_env!("U04_CAPTURE_ROOT")
      File.mkdir_p!(root)

      File.write!(
        Path.join(root, "#{module}-#{depth}-boundary.log"),
        inspect(captured, limit: :infinity, printable_limit: :infinity)
      )
    end

    for module <- @modules do
      pid = Process.whereis(module)
      :sys.replace_state(pid, fn _ -> @secret end)

      result =
        case module do
          Nano.Settings -> Nano.Settings.put("U04_DUMMY_KEY", @secret)
          Nano.ChatGPT.Auth -> Nano.ChatGPT.Auth.refresh(@secret)
          Nano.OpenRouter.Auth -> Nano.OpenRouter.Auth.invalidate_pending()
        end

      assert {:error, message} = result
      refute message =~ @secret
      assert message =~ "did not answer"
      assert message =~ "badmap"
      wait_restart(module, pid)
      refute inspect(events(), limit: :infinity, printable_limit: :infinity) =~ @secret
    end

    previous_trap = Process.flag(:trap_exit, true)

    for module <- @modules do
      {:ok, pid} = GenServer.start_link(module, nil)
      :sys.replace_state(pid, fn _ -> @secret end)
      send(pid, {:"$gen_call", {self(), make_ref()}, crash_message(module)})
      expected = {:shutdown, {:credential_diagnostic, failure_class(module)}}
      assert_receive {:EXIT, ^pid, ^expected}, 1000
    end

    Process.flag(:trap_exit, previous_trap)
    refute inspect(events(), limit: :infinity, printable_limit: :infinity) =~ @secret

    for module <- @modules, reason <- [:normal, :shutdown, {:shutdown, :requested}] do
      {:ok, pid} = GenServer.start(module, nil)
      ref = Process.monitor(pid)
      GenServer.stop(pid, reason)
      assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
    end
  end

  defp wait_restart(module, old, remaining \\ 100) do
    pid = Process.whereis(module)

    cond do
      is_pid(pid) and pid != old ->
        :sys.get_state(pid)

      remaining == 0 ->
        flunk("permanent child did not restart")

      true ->
        Process.sleep(10)
        wait_restart(module, old, remaining - 1)
    end
  end
end
