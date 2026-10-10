defmodule Nano.Flywheel.U02.IsolationTest do
  use ExUnit.Case, async: false

  test "effective defaults and child temporary files stay under this random VM root" do
    root = Application.fetch_env!(:nano, :test_dir)
    assert String.contains?(Path.basename(root), "nano-test-")

    for key <- [:image_dir, :web_cache_dir, :safety_dir, :state_dir, :log_dir, :spill_dir] do
      assert String.starts_with?(Application.fetch_env!(:nano, key), root <> "/")
    end

    assert Nano.Safety.root() == Path.join(root, "safety")
    assert System.get_env("NANO_SAFETY_DIR") == Nano.Safety.root()
    assert System.get_env("NANO_WEB_CACHE_DIR") == Path.join(root, "web")
    assert System.tmp_dir!() == Path.join(root, "tmp")

    {path, 0} =
      System.cmd("python3", [
        "-c",
        "import tempfile; f=tempfile.NamedTemporaryFile(); print(f.name)"
      ])

    assert String.starts_with?(String.trim(path), root <> "/tmp/")
    assert Application.fetch_env!(:nano, NanoWeb.Endpoint)[:http][:port] == 0
    assert Application.fetch_env!(:nano, NanoWeb.Endpoint)[:server] == false
  end

  test "production image and web entry points write default stores, not inherited production locations" do
    root = Application.fetch_env!(:nano, :test_dir)
    gif = Base.decode64!("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
    assert {:ok, ref} = Nano.Images.import_bytes(gif)
    assert {:ok, ^gif} = Nano.Images.read(ref)
    assert File.ls!(Path.join(root, "images")) != []

    {:ok, server} = Bandit.start_link(plug: Nano.WebTest.Page, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    assert {:ok, page} = Nano.Web.fetch("http://127.0.0.1:#{port}/article", js: false)
    assert {:ok, cached} = Nano.Web.read(page.id)
    assert cached.text == page.text
    assert File.exists?(Path.join([root, "web", page.id <> ".json"]))
  end

  test "production environment fallback remains available when optional routing keys are absent" do
    root = Application.fetch_env!(:nano, :test_dir)

    saved =
      for {key, env} <- [web_cache_dir: "NANO_WEB_CACHE_DIR", safety_dir: "NANO_SAFETY_DIR"],
          do: {key, env, Application.fetch_env!(:nano, key), System.fetch_env!(env)}

    on_exit(fn ->
      for {key, env, value, inherited} <- saved do
        Application.put_env(:nano, key, value)
        System.put_env(env, inherited)
      end
    end)

    for {key, env, _, _} <- saved do
      Application.delete_env(:nano, key)
      System.put_env(env, Path.join(root, "fallback-" <> Atom.to_string(key)))
    end

    safety = Path.join(root, "fallback-safety_dir")
    assert Nano.Safety.root() == safety
    File.mkdir_p!(safety)
    File.write!(Path.join(safety, "config.json"), "{}")
    assert :ok = Nano.Safety.backup("u02-fallback.json", ~s({"fake":"fallback"}))
    assert File.exists?(Path.join([safety, "credentials", "u02-fallback.json"]))
    {:ok, server} = Bandit.start_link(plug: Nano.WebTest.Page, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    assert {:ok, page} = Nano.Web.fetch("http://127.0.0.1:#{port}/article", js: false)
    assert {:ok, _} = Nano.Web.read(page.id)
    assert File.exists?(Path.join([root, "fallback-web_cache_dir", page.id <> ".json"]))
  end

  test "default safety backup uses private configured root before publishing credentials" do
    root = Nano.Safety.root()
    File.mkdir_p!(root)
    File.write!(Path.join(root, "config.json"), "{}")
    assert :ok = Nano.Safety.backup("u02-test.json", ~s({"fake":"private"}))
    assert File.read!(Path.join([root, "credentials", "u02-test.json"])) == ~s({"fake":"private"})
    on_exit(fn -> File.rm(Path.join(root, "config.json")) end)
  end
end
