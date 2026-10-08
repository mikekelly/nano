defmodule SeedFocusTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "seed-focus-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root]}
  end

  test "limits, initial bob, distance, compaction and clear", %{opts: opts} do
    assert {:error, _} = SeedFocus.set("a", String.duplicate("é", 1001), opts)
    assert {:ok, _} = SeedFocus.set("a", "remember", opts)

    assert {:ok, %{message: text, events: [%{reason: :new_note}]}} =
             SeedFocus.before_call("a", 100, opts)

    assert text =~ "Your own"
    assert text =~ "written"
    assert {:ok, %{message: nil}} = SeedFocus.before_call("a", 4099, opts)

    assert {:ok, %{events: [%{reason: :threshold, distance_tokens: 4000}]}} =
             SeedFocus.before_call("a", 4100, opts)

    assert {:ok, %{events: [%{reason: :compaction}]}} =
             SeedFocus.before_call("a", 30, [epoch: 1] ++ opts)

    assert {:ok, :cleared} = SeedFocus.clear("a", opts)
    assert {:ok, %{message: nil}} = SeedFocus.before_call("a", 99999, opts)
  end

  test "experimental switches and drift failures are measurable", %{opts: opts} do
    SeedFocus.set("a", "constraint", opts)

    assert {:ok, %{events: [%{type: :focus_configuration}]}} =
             SeedFocus.configure("a", [enabled: false], opts)

    assert {:ok, %{message: nil}} = SeedFocus.before_call("a", 1, opts)
    SeedFocus.configure("a", [enabled: true, drift_enabled: true], opts)

    assert {:ok, %{events: [%{type: :focus_drift_error}, %{type: :focus_bob}]}} =
             SeedFocus.before_call("a", 1, opts)

    SeedFocus.set("a", "constraint", opts)

    adapter = fn "constraint", recent ->
      assert String.length(recent) == 2000
      {:ok, 0.8}
    end

    assert {:ok, %{message: message, events: [%{probability: 0.8}, _]}} =
             SeedFocus.before_call(
               "a",
               2,
               [drift: adapter, recent: String.duplicate("x", 3000)] ++ opts
             )

    assert message =~ "0.8"
    assert {:ok, %{"note" => "constraint"}} = SeedFocus.get("a", opts)
    assert {:error, _} = SeedFocus.configure("a", [threshold: 0], opts)
    assert {:error, _} = SeedFocus.before_call("a", -1, opts)
  end
end
