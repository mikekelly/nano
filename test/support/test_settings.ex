defmodule Nano.TestSettings do
  @moduledoc """
  Sets or clears a node setting (`Nano.Settings`) for one test, and puts back what was there
  when the test ends. Call it from the test process.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  def put(key, value) do
    keep(key)
    :ok = Nano.Settings.put(key, value)
  end

  def delete(key) do
    keep(key)

    case Nano.Settings.delete(key) do
      :ok -> :ok
      {:error, "no setting " <> _} -> :ok
    end
  end

  defp keep(key) do
    {:ok, key} = Nano.Settings.key(key)
    set? = match?(%{set: true}, Enum.find(Nano.Settings.public(), &(&1.key == key)))
    old = Nano.Settings.get(key)
    on_exit(fn -> if set?, do: Nano.Settings.put(key, old), else: Nano.Settings.delete(key) end)
  end
end
