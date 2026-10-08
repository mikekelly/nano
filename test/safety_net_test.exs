defmodule SafetyNetTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "deneb-safety-exunit-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "uninstalled writes are private, atomic and compatible", %{root: root} do
    path = Path.join(root, "settings.json")
    assert :ok = SafetyNet.write_credential(path, ~s({"key":"synthetic"}))
    assert File.read!(path) == ~s({"key":"synthetic"})
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert :ok = SafetyNet.write_credential(path, "{}")
    assert File.read!(path) == "{}"
    assert File.ls!(root) == ["settings.json"]
  end

  test "forget is idempotent without installation", %{root: root} do
    path = Path.join(root, "chatgpt_auth.json")
    assert :ok = SafetyNet.write_credential(path, "synthetic")
    assert :ok = SafetyNet.forget_credential(path)
    assert :ok = SafetyNet.forget_credential(path)
    refute File.exists?(path)
  end

  test "failed write never acknowledges persistence", %{root: root} do
    path = Path.join(root, "occupied")
    File.mkdir!(path)
    assert {:error, _} = SafetyNet.write_credential(path, "synthetic")
    assert File.dir?(path)
    assert File.ls!(root) == ["occupied"]
  end

  test "test home is isolated and served is harmless" do
    assert %{installed: false, liveness: :unknown_check_monitor_timestamp} = SafetyNet.status()

    assert String.starts_with?(
             SafetyNet.status().reports,
             Application.fetch_env!(:nano, :test_dir)
           )

    assert :ok = SafetyNet.served()
    assert :ok = SafetyNet.backup_credentials()
  end
end
