defmodule Nano.Staffing do
  @moduledoc """
  Operator-first staffing: `matrix/0`, `select(:worker)`, `resolve(level: :worker)`,
  `refresh/1`. Exec uses operator exec; lead/worker/grunt inherit engineering.
  `:engineering` aliases worker. Constraints trump rankings; no allowed diversity
  today. Dated evidence/reasons live in `priv/staffing/matrix.json`. Public API
  reference metrics are NOT subscription-provider measurements (explicitly unknown).

  `select/2` takes a stratum atom or explicit model slug, rechecks provider/allowlist
  and supported effort, and preserves the whole window. `resolve/1` is Delegation's
  selector contract: level/stratum are atoms; model may be a stratum atom or slug.
  All supplied strata must agree (engineering=worker). An explicit slug requires a
  role and must match that role's matrix pair, including effort. No silent override.
  `matrix_path:` is opt-in through both selection and Delegation, and is included in
  returned pairs/prompt breadcrumbs. Startup checks again. No settings are changed.

  Cheap refresh: `refresh(path: "/data/staffing/matrix.json")` fetches the one cited
  page via Nano.Web, saves a dated snapshot/hash for review, and leaves old metrics
  dated as before. Review exact pairs and provenance, then submit a candidate with
  `refresh(path: path, data: candidate)`. This validates structure, NOT scientific
  truth or human review: review_required remains true even for submitted data.
  Select/delegate with `matrix_path: path` to opt in. Atomic local rename only;
  concurrent writes are last-writer-wins, no fsync durability guarantee. File/JSON
  input is capped at 64 KiB, 16 pairs, 8 sources, 16 metrics per pair, bounded strings.
  Unknown metrics remain null, never inferred aliases or zero. Future effort strings
  may be recorded, but selection must pass the provider and current operator policy.
  Existing settings policy (not changed here): blank allowlist restores defaults/any;
  duplicate slugs are last-wins. Tightening that policy is a separate operator decision.
  """
  @path Path.expand("../../priv/staffing/matrix.json", __DIR__)
  @strata [:exec, :lead, :worker, :grunt, :engineering]
  @keys ["exec", "lead", "worker", "grunt"]
  @cap 65_536

  def matrix(opts \\ []) do
    safe(fn ->
      with {:ok, bytes} <- bounded_read(opts[:matrix_path] || @path),
           {:ok, data} <- Jason.decode(bytes),
           :ok <- validate(data),
           do: {:ok, data}
    end)
  end

  @doc "Unvalidated provider mapping for legacy inspection; use select/resolve before starting."
  def mapping(choice, opts \\ []) do
    safe(fn ->
      with {:ok, data} <- matrix(opts), do: pair(choice, data, opts)
    end)
  end

  def select(choice, opts \\ []) do
    safe(fn ->
      with {:ok, data} <- matrix(opts),
           {:ok, pair} <- pair(choice, data, opts),
           {:ok, entry} <- (opts[:lookup] || (&Nano.Model.lookup/1)).(pair.model),
           {:ok, checked} <-
             (opts[:check] || (&Nano.Model.check/3)).(
               pair.model,
               pair.effort,
               entry.context_length
             ) do
        {:ok,
         Map.merge(pair, %{
           max_context: checked.context_length,
           dated: data["dated"],
           matrix_path: Path.expand(opts[:matrix_path] || @path)
         })}
      end
    end)
  end

  def resolve(opts) do
    safe(fn ->
      roles =
        Enum.reject(
          [opts[:level], opts[:stratum], if(is_atom(opts[:model]), do: opts[:model])],
          &is_nil/1
        )

      cond do
        roles == [] ->
          {:error, "staffing requires a stratum role (level, stratum or model atom)"}

        Enum.any?(roles, &(&1 not in @strata)) ->
          {:error, "level and stratum must be stratum atoms"}

        length(Enum.uniq(Enum.map(roles, &canonical/1))) != 1 ->
          {:error, "conflicting staffing strata"}

        opts[:model] != nil and not (is_atom(opts[:model]) or is_binary(opts[:model])) ->
          {:error, "invalid model selector"}

        true ->
          role = hd(roles)
          selection_opts = opts |> Keyword.put(:effort, opts[:reasoning])

          with {:ok, mapped} <- mapping(role, selection_opts),
               :ok <- compatible_slug(opts[:model], mapped.model),
               {:ok, selected} <- select(role, selection_opts),
               :ok <- compatible_slug(opts[:model], selected.model) do
            {:ok, Map.put(selected, :level, role)}
          end
      end
    end)
  end

  defp canonical(:engineering), do: :worker
  defp canonical(role), do: role

  defp compatible_slug(model, selected) when is_binary(model) and model != selected,
    do: {:error, "explicit model conflicts with role's matrix pair"}

  defp compatible_slug(_, _), do: :ok

  defp pair(choice, data, opts) when choice in @strata do
    key = choice |> canonical() |> Atom.to_string()
    p = data["strata"][key]

    if opts[:effort] && opts[:effort] != p["effort"] do
      {:error, "stratum effort is fixed by matrix mapping and must be operator-permitted"}
    else
      {:ok, %{model: p["model"], effort: p["effort"], stratum: key, reason: p["reason"]}}
    end
  end

  defp pair(model, _data, opts) when is_binary(model) do
    if slug?(model) and effort?(opts[:effort] || "low") do
      {:ok,
       %{
         model: model,
         effort: opts[:effort] || "low",
         stratum: nil,
         reason: "Explicit model; provider and allowlist must permit it."
       }}
    else
      {:error, "explicit model must be a provider/model slug with a valid effort"}
    end
  end

  defp pair(_, _, _), do: {:error, "expected stratum atom or explicit model slug"}

  def refresh(opts \\ []) do
    safe(fn ->
      path = opts[:path] || "/data/staffing/matrix.json"

      with {:ok, current} <- matrix(opts),
           {:ok, candidate} <- refreshed(current, opts),
           :ok <- validate(candidate),
           {:ok, bytes} <- encode_bounded(candidate),
           :ok <- File.mkdir_p(Path.dirname(path)) do
        temp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"

        try do
          with :ok <- File.write(temp, bytes),
               :ok <- File.rename(temp, path),
               do:
                 {:ok,
                  %{
                    path: path,
                    dated: candidate["dated"],
                    review_required: true,
                    validation: :structural_only,
                    submitted: Keyword.has_key?(opts, :data)
                  }}
        after
          File.rm(temp)
        end
      end
    end)
  end

  defp refreshed(current, opts) do
    if Keyword.has_key?(opts, :data) do
      {:ok, opts[:data]}
    else
      url = hd(current["sources"])["url"]

      with {:ok, page} <-
             Nano.Web.fetch(url, Keyword.merge([refresh: true], opts[:web_opts] || [])) do
        {:ok,
         Map.put(current, "refresh", %{
           "checked_at" => page.fetched_at,
           "url" => page.url,
           "sha256" => page.content_sha256,
           "snapshot" => page.id,
           "review_required" => true
         })}
      end
    end
  end

  defp bounded_read(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, @cap + 1) do
          bytes when is_binary(bytes) and byte_size(bytes) <= @cap -> {:ok, bytes}
          {:error, _} = error -> error
          _ -> {:error, "staffing matrix must be nonempty and at most 64 KiB"}
        end
      after
        File.close(io)
      end
    end
  end

  defp encode_bounded(data) do
    with true <- bounded_term?(data, 0),
         {:ok, bytes} <- Jason.encode(data, pretty: true),
         true <- byte_size(bytes) <= @cap,
         do: {:ok, bytes},
         else: (_ -> {:error, "staffing data exceeds JSON bounds"})
  end

  defp bounded_term?(_, depth) when depth > 8, do: false
  defp bounded_term?(v, _) when is_binary(v), do: byte_size(v) <= 4096 and String.valid?(v)
  defp bounded_term?(v, _) when is_number(v) or is_boolean(v) or is_nil(v), do: true

  defp bounded_term?(v, depth) when is_list(v),
    do: length(v) <= 32 and Enum.all?(v, &bounded_term?(&1, depth + 1))

  defp bounded_term?(v, depth) when is_map(v),
    do:
      map_size(v) <= 32 and
        Enum.all?(v, fn {k, val} ->
          is_binary(k) and bounded_term?(k, depth + 1) and bounded_term?(val, depth + 1)
        end)

  defp bounded_term?(_, _), do: false

  defp validate(data) do
    valid =
      is_map(data) and :erlang.external_size(data) <= @cap and bounded_term?(data, 0) and
        data["schema"] == 1 and date?(data["dated"]) and
        text?(data["constraints"], 4096) and sources?(data["sources"]) and
        pairs?(data["pairs"], data["sources"]) and
        strata?(data["strata"], data["pairs"]) and refresh_evidence?(data["refresh"])

    if valid,
      do: :ok,
      else:
        {:error,
         "invalid bounded staffing matrix: provenance, unique pairs, metrics or stratum references"}
  end

  defp sources?(sources) do
    is_list(sources) and length(sources) in 1..8 and
      Enum.all?(sources, fn s ->
        is_map(s) and url?(s["url"]) and timestamp?(s["fetched_at"]) and hash?(s["sha256"]) and
          text?(s["quote"], 4096) and text?(s["scope"], 1024) and
          optional_text?(s["excerpt_path"], 512)
      end)
  end

  defp pairs?(pairs, sources) do
    is_list(pairs) and length(pairs) in 1..16 and
      Enum.all?(pairs, fn p ->
        is_map(p) and slug?(p["model"]) and effort?(p["effort"]) and text?(p["family"], 128) and
          text?(p["reference_name"], 128) and text?(p["unknown_reason"], 4096) and
          text?(p["billing"], 4096) and
          metrics?(p["reference_metrics"], :reference) and metrics?(p["node_metrics"], :node) and
          is_integer(p["reference_source_index"]) and p["reference_source_index"] >= 0 and
          p["reference_source_index"] < length(sources)
      end) and length(Enum.uniq_by(pairs, &{&1["model"], &1["effort"]})) == length(pairs)
  end

  defp strata?(strata, pairs) do
    is_map(strata) and Enum.sort(Map.keys(strata)) == Enum.sort(@keys) and
      Enum.all?(@keys, fn key ->
        p = strata[key]

        is_map(p) and slug?(p["model"]) and effort?(p["effort"]) and text?(p["reason"], 4096) and
          Enum.count(pairs, &(&1["model"] == p["model"] and &1["effort"] == p["effort"])) == 1
      end)
  end

  defp metrics?(metrics, kind) do
    required =
      if kind == :node,
        do: ["quality", "cost_per_task", "speed"],
        else: ["intelligence_index_v4.3.2", "cost_per_index_task_usd", "output_tokens_per_second"]

    is_map(metrics) and map_size(metrics) in 1..16 and
      Enum.all?(required, &Map.has_key?(metrics, &1)) and
      Enum.all?(metrics, fn {key, value} ->
        text?(key, 128) and
          (is_nil(value) or (is_number(value) and value >= 0 and value <= metric_max(key)))
      end)
  end

  defp metric_max(key) do
    cond do
      String.contains?(key, "percent") or String.starts_with?(key, "intelligence_index") or
          key == "quality" ->
        100

      String.ends_with?(key, "elo") ->
        10_000

      true ->
        1_000_000_000_000
    end
  end

  defp refresh_evidence?(nil), do: true

  defp refresh_evidence?(e),
    do:
      is_map(e) and timestamp?(e["checked_at"]) and url?(e["url"]) and hash?(e["sha256"]) and
        hash?(e["snapshot"]) and e["review_required"] == true

  defp text?(s, max),
    do: is_binary(s) and byte_size(s) in 1..max and String.valid?(s) and String.trim(s) != ""

  defp optional_text?(nil, _), do: true
  defp optional_text?(s, max), do: text?(s, max)
  defp slug?(s), do: text?(s, 256) and Regex.match?(~r/^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.:-]+$/, s)
  defp effort?(s), do: text?(s, 32) and Regex.match?(~r/^[a-z][a-z0-9_-]*$/, s)
  defp date?(s), do: text?(s, 10) and match?({:ok, _}, Date.from_iso8601(s))
  defp timestamp?(s), do: text?(s, 40) and match?({:ok, _, _}, DateTime.from_iso8601(s))
  defp hash?(s), do: is_binary(s) and Regex.match?(~r/^[a-f0-9]{64}$/, s)

  defp url?(s) do
    if text?(s, 2048) do
      uri = URI.parse(s)
      uri.scheme in ["https", "http"] and text?(uri.host, 253) and is_nil(uri.userinfo)
    else
      false
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    error -> {:error, "invalid staffing input: " <> Exception.message(error)}
  catch
    kind, _ -> {:error, "invalid staffing input (#{kind})"}
  end
end
