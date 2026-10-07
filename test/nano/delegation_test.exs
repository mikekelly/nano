defmodule Nano.DelegationTest do
  @moduledoc "The delegation protocol and prompt composition, without spending a model call."
  use ExUnit.Case, async: false

  alias Nano.Delegation

  test "render substitutes vars and includes partials, leaving unknown keys visible" do
    dir = System.tmp_dir!()
    File.write!(Path.join(dir, "part.md"), "PART {{name}}")
    template = "{{>part.md}}\nNAME={{name}} UNKNOWN={{nope}}"
    out = Delegation.render(template, %{"name" => "x"}, dir: dir)
    assert out =~ "PART x"
    assert out =~ "NAME=x"
    assert out =~ "{{nope}}"
  end

  test "a report is a message with the documented shape" do
    me = self()
    parent = "parent-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start(name: parent, start_idle: true)
    _ = pid
    # Nothing to assert about a live agent's mailbox from here; the shape is what matters.
    report = Delegation.report(parent, :done, "hi")
    assert report.from == parent
    assert report.status == :done
    assert report.at =~ "T"
    send(me, {:noop, report})
    assert_received {:noop, _}
  end
end
