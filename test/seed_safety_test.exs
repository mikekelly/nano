defmodule SeedSafetyTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "rigel-safety-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "not installed is explicit", %{dir: dir} do
    assert {:ok, %{"protected" => false, "event" => "not_installed"}} = SeedSafety.status(dir)
  end

  test "rejection files contain only fingerprints and are private", %{dir: dir} do
    assert :ok = SeedSafety.reject("/tmp/settings.json", "key", "never-log-this", dir)
    text = File.read!(Path.join(dir, "rejected.json"))
    refute text =~ "never-log-this"
    assert {:ok, data} = Jason.decode(text)

    assert get_in(data, ["/tmp/settings.json", "key"]) ==
             Base.encode16(:crypto.hash(:sha256, "never-log-this"), case: :lower)

    assert Bitwise.band(File.stat!(Path.join(dir, "rejected.json")).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
  end

  test "ChatGPT rejection fingerprints guard both tokens", %{dir: dir} do
    assert :ok =
             SeedSafety.reject_chatgpt(
               "/tmp/auth.json",
               "synthetic-access",
               "synthetic-refresh",
               dir
             )

    text = File.read!(Path.join(dir, "rejected.json"))
    refute text =~ "synthetic-access"
    assert {:ok, data} = Jason.decode(text)

    assert get_in(data, ["/tmp/auth.json", "@chatgpt"]) ==
             Base.encode16(
               :crypto.hash(:sha256, "synthetic-access" <> <<0>> <> "synthetic-refresh"),
               case: :lower
             )
  end
end

defmodule SeedSafetyDirectoryTest do
  # This test changes environment only in its isolated MIX_ENV=test VM, and must
  # not overlap another ExUnit test that uses those variables in that same VM.
  use ExUnit.Case, async: false

  test "test run directory takes precedence over inherited watchdog environment" do
    run = Application.fetch_env!(:nano, :test_dir)
    inherited = Path.join(run, "inherited-watchdog")
    expected = Path.join(run, "seed-safety")
    old_dir = System.get_env("SEED_SAFETY_DIR")
    old_boot = System.get_env("SEED_SAFETY_BOOT")
    System.put_env("SEED_SAFETY_DIR", inherited)
    System.put_env("SEED_SAFETY_BOOT", "synthetic-test-boot")

    try do
      assert :ok = SeedSafety.reject("/tmp/synthetic-default.json", "key", "synthetic-secret")
      assert File.exists?(Path.join(expected, "rejected.json"))
      refute File.exists?(Path.join(inherited, "rejected.json"))
      assert :ok = SeedSafety.attest(provider: "chatgpt")

      assert {:ok, attestation} =
               Jason.decode(File.read!(Path.join(expected, "attestation.json")))

      assert attestation["boot"] == "synthetic-test-boot"
      assert attestation["providers"] == ["chatgpt"]
      refute File.exists?(Path.join(inherited, "attestation.json"))
    after
      if old_dir,
        do: System.put_env("SEED_SAFETY_DIR", old_dir),
        else: System.delete_env("SEED_SAFETY_DIR")

      if old_boot,
        do: System.put_env("SEED_SAFETY_BOOT", old_boot),
        else: System.delete_env("SEED_SAFETY_BOOT")
    end
  end
end
