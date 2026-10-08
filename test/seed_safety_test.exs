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
end
