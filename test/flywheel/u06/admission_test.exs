defmodule Nano.Flywheel.U06.AdmissionTest do
  use ExUnit.Case, async: false

  test "evidence is synced before publication, with bounded malformed/hash/missing recovery" do
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "u06-evidence")
    text = String.duplicate("é", 500)
    {:ok, handle} = Nano.ContextAdmission.stage(text, root, "agent")
    assert :ok = Nano.ContextAdmission.validate(handle, root, "agent")
    File.write!(handle.path, String.duplicate("a", 1000))
    assert {:error, :unavailable_evidence} = Nano.ContextAdmission.validate(handle, root, "agent")
    assert {:error, :evidence_collision} = Nano.ContextAdmission.stage(text, root, "agent")
    File.rm!(handle.path)

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :before_directory_sync and path =~ "/admission/",
        do: {:error, :injected},
        else: :ok
    end)

    on_exit(fn -> Application.delete_env(:nano, :state_store_fault) end)
    assert {:error, :injected} = Nano.ContextAdmission.stage(text, root, "agent")
    Application.delete_env(:nano, :state_store_fault)
    assert {:ok, ^handle} = Nano.ContextAdmission.stage(text, root, "agent")
    assert :ok = Nano.ContextAdmission.validate(handle, root, "agent")
    assert {:error, :malformed_evidence} = Nano.ContextAdmission.validate(%{}, root, "agent")

    assert {:error, :irreducibly_oversized_evidence} =
             Nano.ContextAdmission.stage(String.duplicate("x", 8_388_609), root, "agent")
  end
end
