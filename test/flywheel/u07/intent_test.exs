defmodule Nano.CredentialIntentTest do
  use ExUnit.Case, async: false
  alias Nano.Safety

  setup do
    root =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "u07-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    state = Path.join(root, "state")
    safety = Path.join(root, "safety")

    saved =
      for key <- [:state_dir, :safety_dir],
          into: %{},
          do: {key, Application.fetch_env!(:nano, key)}

    Application.put_env(:nano, :state_dir, state)
    Application.put_env(:nano, :safety_dir, safety)

    on_exit(fn ->
      Enum.each(saved, fn {key, value} -> Application.put_env(:nano, key, value) end)
      File.rm_rf!(root)
    end)

    %{state: state, safety: safety}
  end

  defp intent(safety), do: Path.join([safety, "credentials", "intent-v1.json"])
  defp barrier(safety), do: Path.join([safety, "credentials", "intent-blocked-v1.json"])

  defp auth,
    do: %{
      "access_token" => "fixture-access",
      "refresh_token" => "fixture-refresh",
      "account_id" => "fixture-account"
    }

  test "BEAM publishers and actual Python Net share lock; owner death releases it", ctx do
    assert Safety.credential_intent_lock_schema() == 1
    assert :ok = Safety.provision_new_credentials(:new_installation)
    assert {:ok, g} = Safety.credential_write("chatgpt_auth.json", auth())
    config = %{app: File.cwd!(), state_dir: ctx.state, command: ["true"]}
    File.write!(Path.join(ctx.safety, "config.json"), Jason.encode!(config))
    parent = self()

    Application.put_env(:nano, :credential_intent_checkpoint, fn stage ->
      if stage == :after_primary do
        send(parent, {:publisher_locked, self()})

        receive do
          :continue -> :ok
        end
      else
        :ok
      end
    end)

    on_exit(fn -> Application.delete_env(:nano, :credential_intent_checkpoint) end)

    script = """
    import sys
    sys.path.insert(0, 'scripts/safety')
    from runner import Net
    net = Net(sys.argv[1])
    class Child:
        def poll(self): return None
    net.child = Child()
    net.stop_child = lambda: (_ for _ in ()).throw(AssertionError('healthy child killed'))
    assert net.credentials() is False
    print('coherent-no-restart')
    """

    for action <- [:refresh, :invalidate, :login] do
      writer =
        spawn(fn ->
          result =
            case action do
              :refresh ->
                Safety.credential_write(
                  "chatgpt_auth.json",
                  Map.put(auth(), "refresh_token", "new"),
                  g
                )

              :invalidate ->
                Safety.credential_invalidate("chatgpt_auth.json")

              :login ->
                Safety.credential_write("chatgpt_auth.json", auth())
            end

          send(parent, {:published, result})
        end)

      assert_receive {:publisher_locked, ^writer}, 2_000
      assert {"coherent-no-restart\n", 0} = System.cmd("python3", ["-c", script, ctx.safety])
      send(writer, :continue)
      assert_receive {:published, {:ok, _}}, 2_000
      assert {"coherent-no-restart\n", 0} = System.cmd("python3", ["-c", script, ctx.safety])
    end

    writer = spawn(fn -> Safety.credential_invalidate("chatgpt_auth.json") end)
    assert_receive {:publisher_locked, ^writer}, 2_000
    monitor = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}
    Application.delete_env(:nano, :credential_intent_checkpoint)
    assert :ok = Safety.reconcile_credentials()
    assert {:ok, %{}, nil} = Safety.credential_read("chatgpt_auth.json")
    assert {"coherent-no-restart\n", 0} = System.cmd("python3", ["-c", script, ctx.safety])
  end

  test "flock tool absence and acquisition timeout fail before credential mutation", ctx do
    assert :ok = Safety.provision_new_credentials(:new_installation)
    assert {:ok, _} = Safety.credential_write("chatgpt_auth.json", auth())
    previous = File.read!(intent(ctx.safety))
    original_path = System.get_env("PATH")
    empty = Path.join(ctx.safety, "empty-tools")
    File.mkdir!(empty)

    try do
      System.put_env("PATH", empty)
      assert {:error, message} = Safety.credential_invalidate("chatgpt_auth.json")
      assert message =~ "maintenance"
    after
      System.put_env("PATH", original_path)
    end

    assert File.read!(intent(ctx.safety)) == previous
    refute File.exists?(barrier(ctx.safety))

    holder =
      Port.open({:spawn_executable, System.find_executable("flock")}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args,
         [
           "-x",
           Path.join([ctx.safety, "credentials", "intent-v1.lock"]),
           "/bin/sh",
           "-c",
           "printf 'locked\\n'; read release"
         ]}
      ])

    assert_receive {^holder, {:data, "locked\n"}}, 2_000

    try do
      assert {:error, message} = Safety.credential_invalidate("chatgpt_auth.json")
      assert message =~ "maintenance"
      assert File.read!(intent(ctx.safety)) == previous
      refute File.exists?(barrier(ctx.safety))
    after
      if Port.info(holder), do: Port.close(holder)
    end

    assert {:ok, nil} = Safety.credential_invalidate("chatgpt_auth.json")
  end

  test "separate nonsecret snapshot wins deletions through credential writes and reconciliation",
       ctx do
    assert :ok = Safety.provision_new_credentials(:new_installation)

    assert {:ok, _} =
             Safety.credential_write("settings.json", %{
               "openrouter_api_key" => "fixture",
               "eval_timeout_ms" => 9
             })

    mixed = File.read!(Path.join(ctx.state, "settings.json"))

    assert :ok =
             Safety.noncredential_settings_write(%{
               "eval_timeout_ms" => 12345,
               "openrouter_api_key" => "must-not-store"
             })

    assert File.read!(Path.join(ctx.state, "settings.json")) == mixed
    ordinary = File.read!(Path.join(ctx.state, "settings-noncredentials-v1.json"))
    refute ordinary =~ "must-not-store"
    assert {:ok, values, _} = Safety.credential_read("settings.json")
    assert values["eval_timeout_ms"] == 12345
    assert values["openrouter_api_key"] == "fixture"

    assert {:ok, _} =
             Safety.credential_write("settings.json", %{
               "openrouter_api_key" => "fresh",
               "eval_timeout_ms" => 999
             })

    assert {:ok, values, _} = Safety.credential_read("settings.json")
    assert values["eval_timeout_ms"] == 12345
    assert :ok = Safety.noncredential_settings_write(%{})
    assert :ok = Safety.reconcile_credentials()
    File.write!(Path.join(ctx.state, "settings.json"), mixed)
    assert {:ok, values, _} = Safety.credential_read("settings.json")
    refute Map.has_key?(values, "eval_timeout_ms")
    assert values["openrouter_api_key"] == "fresh"
  end

  test "explicit provision; revoked generation loses to login and stale refresh", ctx do
    assert {:error, _} = Safety.credential_write("chatgpt_auth.json", auth())
    assert :ok = Safety.provision_new_credentials(:new_installation)
    assert {:ok, g1} = Safety.credential_write("chatgpt_auth.json", auth())

    assert {:ok, ^g1} =
             Safety.credential_write(
               "chatgpt_auth.json",
               Map.put(auth(), "refresh_token", "rotated"),
               g1
             )

    assert {:ok, nil} = Safety.credential_invalidate("chatgpt_auth.json", g1)
    refute File.exists?(Path.join(ctx.state, "chatgpt_auth.json"))
    assert {:error, :stale} = Safety.credential_write("chatgpt_auth.json", auth(), g1)
    assert :ok = Safety.reconcile_credentials()
    assert {:ok, %{}, nil} = Safety.credential_read("chatgpt_auth.json")
    assert {:ok, g2} = Safety.credential_write("chatgpt_auth.json", auth())
    assert g2 > g1
    assert {:error, :stale} = Safety.credential_invalidate("chatgpt_auth.json", g1)

    assert get_in(Jason.decode!(File.read!(intent(ctx.safety))), [
             "entries",
             "chatgpt_auth.json",
             "generation"
           ]) == g2
  end

  test "failures after intent/backup/primary commit preserve invalidation and block until reconciliation",
       ctx do
    for boundary <- [:backup, :primary, :mirror] do
      File.rm_rf!(ctx.state)
      File.rm_rf!(ctx.safety)
      assert :ok = Safety.provision_new_credentials(:new_installation)
      assert {:ok, generation} = Safety.credential_write("chatgpt_auth.json", auth())

      target =
        case boundary do
          :backup -> Path.join([ctx.safety, "credentials", "chatgpt_auth.json"])
          :primary -> Path.join(ctx.state, "chatgpt_auth.json")
          :mirror -> Path.join(ctx.state, "credential-intent-v1.json")
        end

      File.rm!(target)
      File.mkdir!(target)
      assert {:error, _} = Safety.credential_invalidate("chatgpt_auth.json", generation)
      assert File.exists?(barrier(ctx.safety))
      durable = Jason.decode!(File.read!(intent(ctx.safety)))
      assert durable["entries"]["chatgpt_auth.json"]["state"] == "invalidated"
      assert {:error, _} = Safety.credential_write("chatgpt_auth.json", auth())
      assert {:error, _} = Safety.credential_read("chatgpt_auth.json")
      # Compatible restoration retains the newest authority, not an old checkpoint.
      File.rmdir!(target)
      assert :ok = Safety.reconcile_credentials()
      assert {:ok, %{}, nil} = Safety.credential_read("chatgpt_auth.json")
      assert {:error, :stale} = Safety.credential_write("chatgpt_auth.json", auth(), generation)
    end
  end

  test "lost protected authority cannot be recreated from mirror or backup", ctx do
    assert :ok = Safety.provision_new_credentials(:new_installation)
    assert {:ok, _} = Safety.credential_write("chatgpt_auth.json", auth())
    File.rm!(intent(ctx.safety))
    assert {:error, _} = Safety.reconcile_credentials()
    assert {:error, _} = Safety.reconcile_legacy_credentials(:legacy_installation)
    assert {:error, _} = Safety.provision_new_credentials(:new_installation)
    assert {:error, _} = Safety.credential_invalidate("chatgpt_auth.json")
    refute File.exists?(intent(ctx.safety))
  end

  test "legacy reconciliation rejects stale backup-only and conflicting copies, preserves originals",
       ctx do
    File.mkdir_p!(Path.join(ctx.safety, "credentials"))
    File.mkdir_p!(ctx.state)
    backup = Path.join([ctx.safety, "credentials", "chatgpt_auth.json"])
    File.write!(backup, Jason.encode!(auth()))
    assert {:error, _} = Safety.reconcile_legacy_credentials(:legacy_installation)

    File.write!(
      Path.join(ctx.state, "chatgpt_auth.json"),
      Jason.encode!(Map.put(auth(), "refresh_token", "different"))
    )

    assert {:error, _} = Safety.reconcile_legacy_credentials(:legacy_installation)
    File.write!(Path.join(ctx.state, "chatgpt_auth.json"), Jason.encode!(auth()))
    assert :ok = Safety.reconcile_legacy_credentials(:legacy_installation)
    assert {:ok, tokens, _} = Safety.credential_read("chatgpt_auth.json")
    assert tokens == auth()

    [evidence] =
      Path.wildcard(
        Path.join([ctx.safety, "credentials", "legacy-*", "primary-chatgpt_auth.json"])
      )

    assert Jason.decode!(File.read!(evidence)) == auth()
  end

  test "Settings secrets removed by intent never survive older primary and backups", ctx do
    assert :ok = Safety.provision_new_credentials(:new_installation)

    assert {:ok, _} =
             Safety.credential_write("settings.json", %{
               "openrouter_api_key" => "fixture",
               "OTHER_KEY" => "other",
               "eval_timeout_ms" => 1
             })

    assert {:ok, _} =
             Safety.credential_write("settings.json", %{
               "OTHER_KEY" => "other",
               "eval_timeout_ms" => 999
             })

    File.write!(
      Path.join(ctx.state, "settings.json"),
      ~s({"OPENROUTER_API_KEY":"obsolete","other_key":"obsolete-alias","eval_timeout_ms":777})
    )

    assert {:ok, values, _} = Safety.credential_read("settings.json")
    refute Map.has_key?(values, "openrouter_api_key")
    assert values["OTHER_KEY"] == "other"
    assert values["eval_timeout_ms"] == 777
    assert :ok = Safety.reconcile_credentials()
    refute File.read!(Path.join(ctx.state, "settings.json")) =~ "obsolete"
  end
end
