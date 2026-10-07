defmodule Nano.Background.Registry do
  @moduledoc "The unique Registry holding running background task ids (id => pid)."
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: __MODULE__)
end
