defmodule Seedling.BotFiles do
  @moduledoc "Bounded chat attachments copied to opaque local IDs; always served as downloads, never executable inline."
  alias Seedling.CapabilityStore, as: Store

  def add(path, name, opts \\ []) do
    name = Path.basename(name) |> String.slice(0, 160)

    with true <- name != "" and String.valid?(name),
         {:ok, %{type: :regular, size: size}} when size <= 5_000_000 <- File.stat(path),
         {:ok, data} <- File.read(path),
         true <- byte_size(data) <= 5_000_000 do
      id = Store.id()
      dir = Path.join(Store.root(opts), "bot-files")

      image =
        case Nano.Images.import(path) do
          {:ok, ref} -> ref
          _ -> nil
        end

      file = %{"id" => id, "name" => name, "size" => byte_size(data), "image" => image}

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(Path.join(dir, id), data, [:sync]),
           {:ok, _} <- Store.update(:bot_file, id, nil, fn _ -> {:ok, file, file} end, opts),
           do: {:ok, file}
    else
      false -> {:error, :invalid_attachment}
      {:ok, _} -> {:error, :attachment_must_be_regular_under_5mb}
      error -> error
    end
  end

  def get(id, opts \\ []) do
    if is_binary(id) and id =~ ~r/^[a-f0-9]{16}$/ do
      with {:ok, %{} = meta} <- Store.get(:bot_file, id, nil, opts),
           do: {:ok, meta, Path.join([Store.root(opts), "bot-files", id])}
    else
      {:error, :invalid_id}
    end
  end
end
