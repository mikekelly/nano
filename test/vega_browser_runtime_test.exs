defmodule Vega.BrowserRuntimeTest do
  use ExUnit.Case, async: false
  alias Vega.Browser

  test "explicit option wins, exact string setting precedes env/data/PATH, blanks unset" do
    old = Nano.Settings.get("VEGA_BROWSER_NODE")

    on_exit(fn ->
      if old,
        do: Nano.Settings.put("VEGA_BROWSER_NODE", old),
        else: Nano.Settings.delete("VEGA_BROWSER_NODE")
    end)

    assert :ok = Nano.Settings.put("VEGA_BROWSER_NODE", "/browser/runtime-test-setting")
    assert Browser.node_runtime() == "/browser/runtime-test-setting"
    assert Browser.node_runtime(node: "/explicit/runtime") == "/explicit/runtime"
    assert Browser.node_runtime(node: nil) == nil
    assert :ok = Nano.Settings.put("VEGA_BROWSER_NODE", " ")
    selected = Browser.node_runtime()
    env = System.get_env("VEGA_BROWSER_NODE")

    expected =
      if is_binary(env) and String.trim(env) != "",
        do: env,
        else:
          if(File.regular?("/data/vega-browser-tools/node22"),
            do: "/data/vega-browser-tools/node22",
            else: System.find_executable("node22") || System.find_executable("node")
          )

    assert selected == expected
  end

  test "fresh data fallback prefers packaged Node22 over system Node20" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "vega-browser-missing-runtime-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    assert Browser.runtime_fallback(missing, "/image/node22", "/system/node") == "/image/node22"
    assert Browser.runtime_fallback(missing, nil, "/system/node") == "/system/node"
    assert Browser.runtime_fallback("/bin/sh", "/image/node22", "/system/node") == "/bin/sh"
  end

  @tag skip:
         if(File.regular?("/data/vega-browser-tools/node22"),
           do: false,
           else: "stable native Node22 not installed"
         )
  test "default start works with stable native runtime; no opts or env mutation" do
    assert Browser.node_runtime() ==
             (System.get_env("VEGA_BROWSER_NODE") || "/data/vega-browser-tools/node22")

    root =
      Path.join(
        System.tmp_dir!(),
        "vega-browser-runtime-test-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, b} = Browser.start(root: root, agent: nil, notify: self(), lifetime: 15_000)
    assert {:ok, 42} = Browser.evaluate(b, "6*7")
    assert :ok = Browser.stop(b)
    assert_receive {:vega_task, %{status: :stopped}}, 5000
  end
end
