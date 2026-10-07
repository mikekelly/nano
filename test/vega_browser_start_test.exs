defmodule Vega.BrowserStartTest do
  use ExUnit.Case, async: true

  test "failed bridge startup yields task diagnostics and no hanging lifecycle" do
    root =
      Path.join(
        System.tmp_dir!(),
        "vega-browser-start-test-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, %{kind: :browser_start_failed, task_dir: dir}} =
             Vega.Browser.start(
               node: "/bin/false",
               lightpanda: "/bin/false",
               agent: nil,
               root: root
             )

    assert {:ok, %{status: :completed, exit_code: 1}} = Vega.Tasks.status(dir)
    assert {:error, :not_running} = Vega.Tasks.stop(dir)
  end
end
