defmodule Seedling.BotStorageTest do
  use ExUnit.Case, async: true
  alias Seedling.{CapabilityStore, Bots}

  test "corrupt persisted catalog starts blocked instead of stopping the whole node and never overwrites data" do
    root = Path.join(System.tmp_dir!(), "orion-corrupt-bots-" <> CapabilityStore.id())
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, :ok} =
             CapabilityStore.update(:bots, "catalog", nil, fn _ -> {:ok, [], :ok} end, root: root)

    [path] = Path.wildcard(Path.join(root, "*.json"))
    File.write!(path, "broken JSON")
    {:ok, server} = Bots.start_link(name: nil, root: root)
    assert Bots.snapshot(server)["service_error"] =~ "no durable data was overwritten"

    assert {:error, :store_unavailable} =
             Bots.create("New",
               server: server,
               model: "fake",
               reasoning: "off",
               max_context: 20000
             )

    assert File.read!(path) == "broken JSON"
    GenServer.stop(server)
  end
end
