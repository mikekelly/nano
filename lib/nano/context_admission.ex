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

  @queue_max_count 10_000
  @queue_max_bytes 67_108_864
  @record_max_bytes 1_048_576

  # Raw digest/size belongs to the coherent envelope, not the replaceable file.
  # v1 queues had no such authority and remain explicitly unavailable.
  def empty_queue(id, generation),
    do: %{
      version: 2,
      agent_id: id,
      lifecycle_generation: generation,
      read_index: 1,
      write_index: 0,
      count: 0,
      bytes: 0,
      items: %{}
    }

  def queue_push(q, record, root, id, generation) do
    if bound_queue?(q, id, generation) and q.count < @queue_max_count do
      index = q.write_index + 1

      encoded =
        :erlang.term_to_binary(%{
          version: 2,
          agent_id: id,
          lifecycle_generation: generation,
          index: index,
          record: record
        })

      bytes = byte_size(encoded)
      path = queue_path(root, id, generation, index)

      if bytes <= @record_max_bytes and q.bytes + bytes <= @queue_max_bytes do
        with :ok <- File.mkdir_p(Path.dirname(path)), :ok <- keep(path, encoded) do
          entry = %{sha256: sha256(encoded), bytes: bytes}

          {:ok,
           %{
             q
             | write_index: index,
               count: q.count + 1,
               bytes: q.bytes + bytes,
               items: Map.put(q.items, index, entry)
           }}
        end
      else
        {:error, :pending_backlog_limit}
      end
    else
      {:error, :pending_backlog_limit_or_unbound}
    end
  end

  def queue_peek(q, root, id, generation) do
    if bound_queue?(q, id, generation) and q.count > 0 do
      index = q.read_index
      path = queue_path(root, id, generation, index)

      with {:ok, %{sha256: digest, bytes: size}} <- Map.fetch(q.items, index),
           true <-
             is_binary(digest) and digest =~ ~r/\A[0-9a-f]{64}\z/ and
               is_integer(size) and size > 0 and size <= @record_max_bytes and size <= q.bytes,
           {:ok, %{type: :regular, size: ^size}} <- File.lstat(path),
           {:ok, bytes} <- File.read(path),
           true <- sha256(bytes) == digest,
           %{
             version: 2,
             agent_id: ^id,
             lifecycle_generation: ^generation,
             index: ^index,
             record: %{text: text, images: images, evidence: evidence} = record
           } <-
             :erlang.binary_to_term(bytes, [:safe]),
           true <- is_binary(text) and is_list(images) and is_map(evidence) do
        {:ok, record,
         %{
           q
           | read_index: index + 1,
             count: q.count - 1,
             bytes: q.bytes - size,
             items: Map.delete(q.items, index)
         }}
      else
        _ -> {:error, :unavailable_pending_backlog}
      end
    else
      {:error, :empty_or_unbound_pending_backlog}
    end
  rescue
    _ -> {:error, :malformed_pending_backlog}
  end

  @doc false
  def valid_queue?(%{
        version: 2,
        agent_id: id,
        lifecycle_generation: generation,
        read_index: read,
        write_index: write,
        count: count,
        bytes: bytes,
        items: items
      }) do
    is_binary(id) and byte_size(id) <= 512 and is_integer(generation) and generation > 0 and
      is_integer(read) and is_integer(write) and is_integer(count) and is_integer(bytes) and
      is_map(items) and map_size(items) == count and
      read > 0 and write >= 0 and count >= 0 and count <= @queue_max_count and
      write - read + 1 == count and bytes >= 0 and bytes <= @queue_max_bytes and
      ((count == 0 and bytes == 0) or (count > 0 and bytes > 0))
  end

  def valid_queue?(_), do: false

  defp bound_queue?(q, id, generation),
    do: valid_queue?(q) and q.agent_id == id and q.lifecycle_generation == generation

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp queue_path(root, id, generation, index),
    do: Path.join([root, id, "pending-v2", "#{generation}-#{index}.term"])

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
