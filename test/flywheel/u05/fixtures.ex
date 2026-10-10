defmodule Nano.Flywheel.U05.Fixture do
  @moduledoc false
  # Explicit disposable-test corruption/legacy-shape injection, NOT a save API.
  def commit_live(name, map) do
    pid = NanoAgent.whereis(name)
    :sys.replace_state(pid, fn s -> Map.merge(s, map) end)
    GenServer.cast(pid, :resave)
    :sys.get_state(pid)
    :ok
  end

  def put(name, map) do
    if pid = NanoAgent.whereis(name), do: :sys.get_state(pid)
    path = Path.join(Application.fetch_env!(:nano, :state_dir), name <> ".envelope-v1")

    if File.exists?(path) do
      envelope = path |> File.read!() |> :erlang.binary_to_term()
      :ok = Nano.StateStore.write_file("test fixture", path, %{envelope | metadata: map})
    end

    :ets.insert(Nano.StateStore, {name, map})
    :ok
  end
end
