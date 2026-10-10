defmodule Nano.Flywheel.Data do
  @moduledoc """
  Information at the graph boundary is bounded inert data. Caller atom keys/values
  become strings without interning artifact text. Only the fixed internal protocol
  retains atoms, so safe external-term decoding works in a fresh VM. Non-data values
  (functions, references, ports and pids) reject rather than become executable state.
  """
  @max_bytes 128_000
  def normalize(value) do
    if :erlang.external_size(value) > @max_bytes, do: throw(:invalid_evidence)
    result = convert(value, 0)
    if :erlang.external_size(result) > @max_bytes, do: throw(:invalid_evidence)
    result
  end

  # Fixed structural keys remain atoms; every other caller key/value becomes inert text.
  def fields(map, fixed) when is_map(map) do
    keys = Map.keys(map)
    extras = keys -- fixed
    normalized = normalize(Map.take(map, extras))

    Enum.reduce(fixed, normalized, fn key, acc ->
      if Map.has_key?(map, key), do: Map.put(acc, key, normalize(map[key])), else: acc
    end)
  end

  defp convert(x, _) when is_binary(x) or is_number(x) or is_boolean(x) or is_nil(x), do: x
  defp convert(x, _) when is_atom(x), do: Atom.to_string(x)
  defp convert(_, depth) when depth > 40, do: throw(:invalid_evidence)
  defp convert(x, depth) when is_list(x), do: Enum.map(x, &convert(&1, depth + 1))
  defp convert(x, depth) when is_tuple(x), do: convert(Tuple.to_list(x), depth + 1)

  defp convert(x, depth) when is_map(x) and not is_struct(x) do
    pairs =
      Enum.map(x, fn {key, value} ->
        key = if is_atom(key), do: Atom.to_string(key), else: key
        if not is_binary(key), do: throw(:invalid_evidence)
        {key, convert(value, depth + 1)}
      end)

    if length(pairs) != length(Enum.uniq_by(pairs, &elem(&1, 0))), do: throw(:invalid_evidence)
    Map.new(pairs)
  end

  defp convert(_, _), do: throw(:invalid_evidence)
end
