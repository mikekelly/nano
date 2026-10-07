defmodule Vega.BotsContextWorkspaceTest.Runtime do
  def deliver(_, _, _, _), do: :ok
  def notify(_, _), do: {:error, :not_found}
  def info(_), do: nil
end

defmodule Vega.BotsContextWorkspaceTest do
  use ExUnit.Case, async: true
  alias Vega.Bots

  setup do
    root = Path.join(System.tmp_dir!(), "bots-context-workspace-" <> Vega.Store.id())

    {:ok, pid} =
      start_supervised(
        {Vega.Bots.Server,
         name: {:global, {:workspace_test, root}},
         root: root,
         runtime: Vega.BotsContextWorkspaceTest.Runtime}
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, opts: [server: pid], name: {:global, {:workspace_test, root}}}
  end

  defp bot(name, opts) do
    {:ok, b} =
      Bots.create_bot(
        name,
        opts ++ [model: "test", reasoning: "off", max_context: 80000, max_turns: 0, max_tokens: 0]
      )

    b
  end

  test "bounded shared context has peer names, UTF8 byte limits and exact recovery", c do
    muse = bot("Muse", c.opts)
    dot = bot("Dot", c.opts)
    {:ok, group} = Bots.create_session([muse["id"], dot["id"]], c.opts)
    {:ok, private} = Bots.create_session([dot["id"]], c.opts)
    {:ok, _} = Bots.post(private["id"], dot["id"], "PRIVATE_SECRET", c.opts)
    long = "LATEST_PEER " <> String.duplicate("🌿", 700) <> " FULL_SUFFIX"

    for i <- 1..35,
        do: Bots.post(group["id"], dot["id"], "peer #{i} " <> long, c.opts ++ [proactive: true])

    {:ok, session} = Bots.get_session(group["id"], c.opts)
    session = Map.put(session, "routing_participants", [%{"id" => dot["id"], "name" => "Dot"}])
    ctx = Vega.Bots.Context.recent(session, "not-current")
    records = ctx["recent_messages"]
    assert length(records) <= 20
    assert byte_size(Jason.encode!(records)) <= 8000

    assert Enum.all?(
             records,
             &(byte_size(&1["text"]) <= 1000 and String.valid?(&1["text"]) and
                 &1["text_truncated"])
           )

    assert List.last(records)["author_name"] == "Dot"
    refute Jason.encode!(ctx) =~ "PRIVATE_SECRET"
    meta = ctx["recent_messages_meta"]
    assert meta["omitted_older_messages"] > 0
    assert meta["total_prior_messages"] == 35
    {:ok, older} = Bots.get_session(group["id"], c.opts ++ [before: meta["before_cursor"]])
    assert older["messages"] != []
    {:ok, full} = Bots.get_message(group["id"], List.last(records)["id"], c.opts)
    assert full["text"] =~ "FULL_SUFFIX"
    assert byte_size(full["text"]) > 1000
  end

  test "two bots have stable separate identity computers and session shell cwd", c do
    muse = bot("Muse", c.opts)
    dot = bot("Dot", c.opts)
    {:ok, a} = Bots.create_session([muse["id"]], c.opts)
    {:ok, b} = Bots.create_session([muse["id"], dot["id"]], c.opts)
    {:ok, wa} = Bots.workspace(muse["id"], c.opts ++ [session_id: a["id"]])
    {:ok, wb} = Bots.workspace(muse["id"], c.opts ++ [session_id: b["id"]])
    {:ok, wd} = Bots.workspace(dot["id"], c.opts ++ [session_id: b["id"]])
    assert wa["identity"] == wb["identity"]
    refute wa["session"] == wb["session"]
    refute wa["identity"] == wd["identity"]
    assert muse["workspace"] == wa["identity"]
    assert File.dir?(wa["session"])
    assert {:error, :wrong_session} = Bots.workspace(dot["id"], c.opts ++ [session_id: a["id"]])
    assert {:error, :invalid_bot_id} = Vega.Bots.Workspace.ensure(c.root, "../escape", a["id"])

    {:ok, result} =
      Bots.shell(
        muse["id"],
        a["id"],
        "pwd",
        c.opts ++ [cwd: "/tmp", output_dir: Path.join(c.root, "shell-results")]
      )

    assert result.status == 0
    assert String.trim(result.output) == wa["session"]
    File.write!(Path.join(wa["identity"], "retained.txt"), "stable artifact")
    stop_supervised(Vega.Bots.Server)

    {:ok, pid} =
      start_supervised(
        {Vega.Bots.Server,
         name: c.name, root: c.root, runtime: Vega.BotsContextWorkspaceTest.Runtime}
      )

    {:ok, restored} = Bots.workspace(muse["id"], server: pid, session_id: a["id"])
    assert restored == wa
    assert File.read!(Path.join(restored["identity"], "retained.txt")) == "stable artifact"
  end
end
