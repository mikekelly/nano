defmodule Nano.ContextAdmission do
  @moduledoc """
  Context admission v1. Exact staged text is content-addressed under the agent's durable
  spill root. A handle records identity, byte count and position (zero until explicitly
  read); staging is not acknowledgment of reading or answering. State readers must retain
  these handles and pending delivery order. No downgrade may discard newer pending items.
  Images remain immutable image references, not a claim that pixels are retained in text.
  """
  @maximum 8_388_608

  def item_limit(0), do: 51_200
  def item_limit(window), do: max(512, min(51_200, div(window, 8)))

  def stage(text, root, id) when is_binary(text) do
    if byte_size(text) > @maximum or not String.valid?(text) do
      {:error, :irreducibly_oversized_evidence}
    else
      hash = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
      path = Path.join([root, id, "admission", hash <> ".txt"]) |> Path.expand()

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- keep(path, text) do
        {:ok, %{version: 1, sha256: hash, path: path, bytes: byte_size(text), position: 0}}
      end
    end
  end

  defp keep(path, text) do
    # Re-publish identical bytes through the shared synced-publication protocol so a
    # previous uncertain directory-sync failure cannot turn a retry into false durability.
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size == byte_size(text) ->
        case File.read(path) do
          {:ok, ^text} -> Nano.StateStore.write_bytes("context admission", path, text)
          _ -> {:error, :evidence_collision}
        end

      {:error, :enoent} ->
        Nano.StateStore.write_bytes("context admission", path, text)

      _ ->
        {:error, :evidence_collision}
    end
  end

  def validate(%{version: 1, sha256: hash, path: path, bytes: bytes, position: pos}, root, id)
      when is_binary(hash) and is_binary(path) and is_integer(bytes) and
             bytes >= 0 and bytes <= @maximum and is_integer(pos) and pos >= 0 and pos <= bytes do
    expected = Path.expand(Path.join([root, id, "admission", hash <> ".txt"]))

    with true <- hash =~ ~r/\A[0-9a-f]{64}\z/ and path == expected,
         {:ok, %{type: :regular, size: ^bytes}} <- File.lstat(path),
         {:ok, text} <- File.read(path),
         true <- Base.encode16(:crypto.hash(:sha256, text), case: :lower) == hash do
      :ok
    else
      _ -> {:error, :unavailable_evidence}
    end
  end

  def validate(_, _, _), do: {:error, :malformed_evidence}

  def notice(h) do
    "<harness>Staged exact evidence, not read or answered: #{h.path}; " <>
      "SHA-256 #{h.sha256}; #{h.bytes} UTF-8 bytes; continuation position #{h.position}. " <>
      "Read/page this file explicitly when needed. This notice is not the evidence contents.</harness>"
  end

  # Only complete tool groups are eligible checkpoint prefixes.
  def boundaries(messages) do
    {positions, _} =
      messages
      |> Enum.with_index(1)
      |> Enum.reduce({[], MapSet.new()}, fn {m, n}, {acc, open} ->
        open =
          case m do
            %{"role" => "assistant", "tool_calls" => calls} ->
              Enum.reduce(calls, open, &MapSet.put(&2, &1["id"]))

            %{"role" => "tool", "tool_call_id" => id} ->
              MapSet.delete(open, id)

            _ ->
              open
          end

        {if(MapSet.size(open) == 0, do: [n | acc], else: acc), open}
      end)

    Enum.reverse(positions)
  end
end
