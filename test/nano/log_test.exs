defmodule Nano.LogTest do
  # Not async: one test points :log_dir somewhere else.
  use ExUnit.Case, async: false

  setup do
    id = "log-test-#{System.unique_integer([:positive])}"
    %{agent: %{id: id, name: "log-test"}, id: id}
  end

  test "write appends JSONL, broadcasts the same entry, and read/2 filters by seq", %{
    agent: agent,
    id: id
  } do
    Nano.Log.subscribe(id)

    entry =
      Nano.Log.write(agent, :event_received, %{
        event_seq: 1,
        message: ":hi",
        from: self(),
        pair: {1, 2}
      })

    assert_receive {:nano_log, ^entry}

    pid = inspect(self())

    assert %{
             seq: 1,
             type: :event_received,
             agent_id: ^id,
             agent: "log-test",
             from: ^pid,
             pair: "{1, 2}",
             at: at
           } = entry

    assert {:ok, _, 0} = DateTime.from_iso8601(at)

    Nano.Log.write(agent, :turn_ended, %{reason: "idle", bad: <<255>>})

    assert [
             %{"seq" => 1, "type" => "event_received", "from" => ^pid},
             %{"seq" => 2, "bad" => "<<255>>"}
           ] =
             Nano.Log.read(id)

    assert [%{"seq" => 2, "reason" => "idle"}] = Nano.Log.read(id, 1)
    assert Nano.Log.read(id, 2) == []
    assert Nano.Log.read("no-such-agent") == []
  end

  test "write creates the log directory if it does not exist", %{agent: agent, id: id} do
    saved = Application.fetch_env!(:nano, :log_dir)

    dir =
      Path.join([
        System.tmp_dir!(),
        "nano-log-test-#{System.unique_integer([:positive])}",
        "logs"
      ])

    Application.put_env(:nano, :log_dir, dir)

    on_exit(fn ->
      Application.put_env(:nano, :log_dir, saved)
      File.rm_rf!(Path.dirname(dir))
    end)

    refute File.exists?(dir)
    Nano.Log.write(agent, :turn_ended, %{reason: "idle"})
    assert File.exists?(Path.join(dir, id <> ".jsonl"))
    assert [%{"reason" => "idle"}] = Nano.Log.read(id)
  end
end
