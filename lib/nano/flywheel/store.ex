defmodule Nano.Flywheel.Store do
  @moduledoc """
  Version 1 coherent snapshots. Sync temporary file, rename, sync filesystem before
  acknowledgment. Uncertain writes quarantine owner until explicit reconciliation.
  Downgrade to code without generation/reservation support is forbidden.
  """
  def read(root) do
    case File.read(Path.join(root, "state.term")) do
      {:ok, bytes} when byte_size(bytes) <= 16_000_000 ->
        try do
          # Only fixed protocol atoms persist; caller/artifact information is inert text.
          case :erlang.binary_to_term(bytes, [:safe]) do
            %{schema_version: 1} = s -> if valid?(s), do: {:ok, s}, else: {:error, :corrupt_state}
            _ -> {:error, :unsupported_state}
          end
        rescue
          _ -> {:error, :corrupt_state}
        end

      {:ok, _} ->
        {:error, :state_too_large}

      {:error, :enoent} ->
        {:ok, nil}

      error ->
        error
    end
  end

  defp valid?(s) do
    data_only?(s) and is_binary(s[:owner]) and is_integer(s[:owner_generation]) and
      s.owner_generation >= 0 and
      is_integer(s[:revision]) and s.revision >= 0 and is_map(s[:units]) and
      is_map(s[:operations]) and is_list(s[:history]) and is_list(s[:provenance]) and
      Enum.all?(s.units, fn {id, u} ->
        is_binary(id) and is_map(u) and is_map(u[:description]) and u.description[:id] == id and
          is_list(u[:scopes]) and is_list(u[:history]) and is_map(u[:stages]) and
          is_boolean(u[:done]) and is_integer(u[:claim_generation]) and u.claim_generation >= 0 and
          is_integer(u[:integration_generation]) and u.integration_generation >= 0 and
          (u[:claim] == nil or is_map(u.claim)) and
          (u[:reservation] == nil or is_map(u.reservation))
      end)
  rescue
    _ -> false
  end

  defp data_only?(x) when is_function(x) or is_reference(x) or is_port(x) or is_pid(x), do: false

  defp data_only?(x) when is_map(x),
    do: Enum.all?(x, fn {k, v} -> data_only?(k) and data_only?(v) end)

  defp data_only?(x) when is_list(x), do: Enum.all?(x, &data_only?/1)
  defp data_only?(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.all?(&data_only?/1)
  defp data_only?(_), do: true

  def write(root, state) do
    # Pids are monitor observations, never durable authority. Restart reconciles names/generations.
    units =
      Map.new(state.units, fn {id, u} ->
        {id, if(u.claim, do: %{u | claim: Map.delete(u.claim, :pid)}, else: u)}
      end)

    state = %{state | units: units}
    path = Path.join(root, "state.term")

    with true <- valid?(state) || {:error, :invalid_state},
         true <- :erlang.external_size(state) <= 16_000_000 || {:error, :state_too_large},
         :ok <- File.mkdir_p(root),
         {:ok, io} <- :file.open(String.to_charlist(path <> ".next"), [:write, :binary, :raw]) do
      result =
        with :ok <- :file.write(io, :erlang.term_to_binary(state)), :ok <- :file.sync(io), do: :ok

      closed = :file.close(io)

      with :ok <- result,
           :ok <- closed,
           :ok <- File.rename(path <> ".next", path),
           {_, 0} <- System.cmd("sync", ["-f", root], stderr_to_stdout: true),
           do: :ok
    end
  rescue
    _ -> {:error, :write_failed}
  end
end
