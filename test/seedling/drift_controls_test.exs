defmodule Seedling.DriftControlsTest do
  use ExUnit.Case, async: true
  alias Seedling.{FrontOfMind, CapabilityStore, Decision}

  test "drift is independent of bobbing, image content is safe and hint survives until next bob" do
    root = Path.join(System.tmp_dir!(), "orion-drift-" <> CapabilityStore.id())
    name = "drift-" <> CapabilityStore.id()
    on_exit(fn -> File.rm_rf(root) end)

    transport = fn opts ->
      assert opts[:json].state.activity =~ "nano_image"

      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "fake-jev",
           "answers" => %{"drift" => %{"type" => "noul", "noul" => 0.85}}
         }
       }}
    end

    opts = [root: root, decision_opts: [key: "test-only", transport: transport]]

    s = %{
      name: name,
      id: name,
      request_id: 0,
      transcript: [
        %{"role" => "user", "content" => [%{"type" => "nano_image", "id" => "opaque"}]}
      ]
    }

    assert {:ok, :ok} = FrontOfMind.set(name, "Keep the hotel budget below £200", opts)
    assert {:ok, :ok} = FrontOfMind.configure(name, [enabled: false, drift: true], opts)
    off = FrontOfMind.before_request(s, opts)
    assert off.transcript == s.transcript
    assert off.seedling_drift_hint =~ "0.85"

    assert Enum.any?(
             Nano.Log.read(name),
             &(&1["type"] == "drift_judgement" and &1["enabled"] == false)
           )

    assert {:ok, :ok} = FrontOfMind.configure(name, [enabled: true], opts)
    on = FrontOfMind.before_request(off, opts)
    assert length(on.transcript) == 2
    assert List.last(on.transcript)["content"] =~ "drift probability 0.85"
    assert {:ok, :ok} = FrontOfMind.configure(name, [drift: false], opts)
    before = Enum.count(Nano.Log.read(name), &(&1["type"] == "drift_judgement"))
    FrontOfMind.before_request(%{on | request_id: 20}, opts)
    assert Enum.count(Nano.Log.read(name), &(&1["type"] == "drift_judgement")) == before
  end

  test "sanitized actionable timeout and programming adapter errors retain no secret" do
    q = %{"urgent" => Decision.noul("Urgent?")}

    assert {:error, {:decision_unavailable, :timeout}} =
             Decision.evaluate("state", q,
               key: "do-not-leak",
               transport: fn _ -> {:error, %{reason: :timeout, detail: "do-not-leak"}} end
             )

    assert {:error, {:adapter_error, ArgumentError}} =
             Decision.evaluate("state", q,
               key: "do-not-leak",
               transport: fn _ -> raise ArgumentError, "do-not-leak" end
             )
  end
end
