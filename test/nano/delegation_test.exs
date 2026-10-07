defmodule Nano.DelegationTest do
  # Not async: the delegation store, ETS caches and env vars are node-wide.
  use ExUnit.Case, async: false

  alias Nano.Delegation, as: D

  setup do
    dir = Path.join(System.tmp_dir!(), "nano-del-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = System.get_env("NANO_DATA_DIR")
    System.put_env("NANO_DATA_DIR", dir)

    on_exit(fn ->
      if old, do: System.put_env("NANO_DATA_DIR", old), else: System.delete_env("NANO_DATA_DIR")
      File.rm_rf(dir)
      :ets.delete_all_objects(Nano.Delegation.Store.table())
    end)

    %{dir: dir}
  end

  test "render substitutes vars and expands partials" do
    dir = Path.join(System.tmp_dir!(), "tpl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "identity.md"), "I am {{name}}.")
    File.write!(Path.join(dir, "job.md"), "{{>identity.md}}\\nJob: {{job}}")
    on_exit(fn -> File.rm_rf(dir) end)

    out =
      D.render(File.read!(Path.join(dir, "job.md")), %{"name" => "scout", "job" => "read"},
        dir: dir
      )

    assert out =~ "I am scout."
    assert out =~ "Job: read"
  end

  test "render leaves unknown placeholders visible" do
    assert D.render("hello {{nope}}", %{}) == "hello {{nope}}"
  end

  test "render stops expanding a self-referential partial" do
    dir = Path.join(System.tmp_dir!(), "loop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.md"), "{{>a.md}}")
    on_exit(fn -> File.rm_rf(dir) end)
    # Depth-limited, so it returns rather than looping forever.
    assert D.render(File.read!(Path.join(dir, "a.md")), %{}, dir: dir) =~ "{{>a.md}}"
  end

  test "file_blocks include a path and a content hash" do
    path = Path.join(System.tmp_dir!(), "blk-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "content here")
    on_exit(fn -> File.rm(path) end)
    block = D.file_blocks([path])
    assert block =~ ~s(<file path="#{path}")
    assert block =~ "hash="
    assert block =~ "content here"
  end

  test "file_blocks report an unreadable file without raising" do
    block = D.file_blocks(["/nonexistent/xyz"])
    assert block =~ "unreadable"
  end

  test "worktree/2 needs a real git sha" do
    sha = String.trim(Nano.Util.sh("git -C /app rev-parse HEAD").out)
    name = "wt-test-#{System.unique_integer([:positive])}"
    assert {:ok, path} = D.worktree(name, sha)
    assert File.dir?(path)
    assert String.trim(Nano.Util.sh("git -C #{path} rev-parse HEAD").out) == sha
    assert {:ok, ^path} = D.worktree(name, sha)
    assert {:error, {:worktree_exists, _, _}} = D.worktree(name, String.duplicate("0", 40))
    D.remove_worktree(name)
  end

  test "report_to sends a {:report, map} to the parent" do
    assert :ok = D.report_to(self(), :done, "all good")
    assert_receive {:report, %{status: :done, message: "all good", from: _}}
  end

  test "brief names the parent and the report function" do
    text = D.brief("scout", "gardener", [{"a.md", "abc123"}], nil, [])
    assert text =~ "sub-agent started by gardener"
    assert text =~ ~s|Nano.Delegation.report_to("gardener"|
    assert text =~ "a.md"
  end

  test "wait matches a report by name and times out otherwise" do
    spawn(fn -> Process.send_after(self(), :never, 10_000) end)
    assert {:error, :timeout} = D.wait("nobody", 100)
  end

  test "the store records and replays parent/child relationships" do
    Nano.Delegation.Store.remember("kid", "parent-x", %{worktree: "/tmp/w"})
    [entry] = Nano.Delegation.Store.children("parent-x")
    assert entry["name"] == "kid"
    assert entry["worktree"] == "/tmp/w"
    assert Nano.Delegation.Store.parent_of("kid") == "parent-x"
  end

  test "subagents lists children of the calling agent with live status" do
    Nano.Delegation.Store.remember("kid2", "gardener")
    rows = D.subagents("gardener")
    assert Enum.any?(rows, &(&1.name == "kid2" and &1.parent == "gardener"))
  end
end
