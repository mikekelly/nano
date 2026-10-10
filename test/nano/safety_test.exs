defmodule Nano.SafetyTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "altair-safety-unit-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "status distinguishes absent, stale, disabled and protected", %{root: root} do
    assert %{protected: false, state: "not_installed"} = Nano.Safety.status(root)
    path = Path.join(root, "status.json")
    File.write!(path, Jason.encode!(%{state: "watching", updated: 0}))
    refute Nano.Safety.status(root)["protected"]

    File.write!(
      path,
      Jason.encode!(%{
        state: "watching",
        updated: System.system_time(:second),
        child_pid: System.pid()
      })
    )

    assert Nano.Safety.status(root)["protected"]
    File.touch!(Path.join(root, "disabled"))
    refute Nano.Safety.status(root)["protected"]
    File.write!(path, "[]")
    assert %{protected: false, state: "invalid_status"} = Nano.Safety.status(root)
  end

  test "write-through copies latest credentials atomically with secret permissions", %{root: root} do
    File.write!(Path.join(root, "config.json"), "{}")
    target = Path.join([root, "credentials", "chatgpt_auth.json"])

    assert :ok =
             Nano.Safety.backup(
               "/irrelevant/chatgpt_auth.json",
               ~s({"refresh_token":"fake-old"}),
               root
             )

    latest = ~s({"refresh_token":"fake-rotated"})
    assert :ok = Nano.Safety.backup("/irrelevant/chatgpt_auth.json", latest, root)
    assert File.read!(target) == latest
    assert :ok = Nano.Safety.backup("/irrelevant/chatgpt_auth.json", "{}", root)
    assert File.read!(target) == latest
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(target)).mode, 0o777) == 0o700
    assert File.ls!(Path.dirname(target)) == ["chatgpt_auth.json"]
  end

  test "deleting a secret cannot erase its recovery copy", %{root: root} do
    File.write!(Path.join(root, "config.json"), "{}")

    assert :ok =
             Nano.Safety.backup(
               "settings.json",
               ~s({"openrouter_api_key":"fake-old","node_max_tokens_per_hour":1}),
               root
             )

    assert :ok =
             Nano.Safety.backup(
               "settings.json",
               ~s({"node_max_tokens_per_hour":999,"OTHER_KEY":"fake-new"}),
               root
             )

    saved = Jason.decode!(File.read!(Path.join([root, "credentials", "settings.json"])))
    assert saved["openrouter_api_key"] == "fake-old"
    assert saved["node_max_tokens_per_hour"] == 999
    assert saved["OTHER_KEY"] == "fake-new"
  end

  test "backup unavailable is an error, not silently successful", %{root: root} do
    File.write!(Path.join(root, "config.json"), "{}")
    File.write!(Path.join(root, "credentials"), "blocking file")
    assert {:error, _} = Nano.Safety.backup("settings.json", ~s({"key":"fake"}), root)
  end

  test "uninstalled copies do not write anywhere", %{root: root} do
    assert :ok = Nano.Safety.backup("settings.json", ~s({"key":"fake"}), root)
    refute File.exists?(Path.join(root, "credentials"))
  end
end
