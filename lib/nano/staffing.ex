defmodule Nano.Staffing do
  @moduledoc """
  Operator-first staffing: `matrix/0`, `select(:worker)`, `refresh/1`.
  Exec uses operator exec; lead/worker/grunt inherit engineering. `:engineering`
  aliases worker. Constraints trump rankings; no allowed family diversity today.
  Dated evidence/reasons live in `priv/staffing/matrix.json`. Public API reference
  metrics are NOT exact subscription-provider measurements (explicitly unknown).

  `select/2` takes a stratum or explicit model slug, rechecks provider/allowlist and
  preserves the whole window. Startup checks again. No settings are changed.

  Cheap refresh: `refresh(path: "/data/staffing/matrix.json")` fetches the single
  cited page via Nano.Web, saves a dated snapshot/hash for review, and leaves old
  metrics dated as before. Review the snapshot, update a candidate map with exact
  pair metrics and provenance, then `refresh(path: path, data: candidate)` persists
  it atomically. Select with `matrix_path: path` to opt into reviewed data. The
  shipped matrix stays the default. Never infer aliases or turn unknown into zero.
  """
  @path Path.expand("../../priv/staffing/matrix.json", __DIR__)
  @strata [:exec, :lead, :worker, :grunt, :engineering]
  def matrix(opts \\ []) do
    with {:ok, bytes} <- File.read(opts[:matrix_path] || @path),
         {:ok, data} <- Jason.decode(bytes),
         :ok <- validate(data),
         do: {:ok, data}
  end

  @doc "Unvalidated mapping for inspection/legacy Delegation.model; use select before starting."
  def mapping(choice, opts \\ []) do
    with {:ok, data} <- matrix(opts), do: pair(choice, data, opts)
  end

  def select(choice, opts \\ []) do
    with {:ok, data} <- matrix(opts),
         {:ok, pair} <- pair(choice, data, opts),
         {:ok, entry} <- (opts[:lookup] || (&Nano.Model.lookup/1)).(pair.model),
         {:ok, checked} <-
           (opts[:check] || (&Nano.Model.check/3)).(pair.model, pair.effort, entry.context_length) do
      {:ok, Map.merge(pair, %{max_context: checked.context_length, dated: data["dated"]})}
    end
  end

  defp pair(choice, data, opts) when choice in @strata do
    key = if choice == :engineering, do: "worker", else: Atom.to_string(choice)
    p = data["strata"][key]

    if opts[:effort] && opts[:effort] != p["effort"] do
      {:error, "stratum effort is fixed by operator mapping"}
    else
      {:ok, %{model: p["model"], effort: p["effort"], stratum: key, reason: p["reason"]}}
    end
  end

  defp pair(model, _data, opts) when is_binary(model) do
    {:ok,
     %{
       model: model,
       effort: opts[:effort] || "low",
       stratum: nil,
       reason: "Explicit model; provider and allowlist must permit it."
     }}
  end

  defp pair(_, _, _),
    do: {:error, "expected exec/lead/worker/grunt/engineering stratum or explicit model slug"}

  def refresh(opts \\ []) do
    path = opts[:path] || "/data/staffing/matrix.json"

    with {:ok, current} <- matrix(opts),
         {:ok, candidate} <- refreshed(current, opts),
         :ok <- validate(candidate),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      temp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"

      try do
        with :ok <- File.write(temp, Jason.encode!(candidate, pretty: true)),
             :ok <- File.rename(temp, path),
             do:
               {:ok,
                %{
                  path: path,
                  dated: candidate["dated"],
                  review_required: not Keyword.has_key?(opts, :data)
                }}
      after
        File.rm(temp)
      end
    end
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

  defp validate(data) when is_map(data) do
    valid =
      data["schema"] == 1 and is_binary(data["dated"]) and
        match?({:ok, _}, Date.from_iso8601(data["dated"])) and
        is_list(data["sources"]) and data["sources"] != [] and
        Enum.all?(
          data["sources"],
          &(is_map(&1) and is_binary(&1["url"]) and is_binary(&1["fetched_at"]) and
              is_binary(&1["sha256"]))
        ) and
        is_list(data["pairs"]) and data["pairs"] != [] and
        Enum.all?(data["pairs"], fn p ->
          is_map(p) and is_binary(p["model"]) and p["effort"] == "low" and
            is_map(p["reference_metrics"]) and is_map(p["node_metrics"]) and
            is_binary(p["unknown_reason"]) and is_integer(p["reference_source_index"]) and
            p["reference_source_index"] >= 0 and
            p["reference_source_index"] < length(data["sources"])
        end) and
        is_map(data["strata"]) and
        Enum.all?(["exec", "lead", "worker", "grunt"], fn key ->
          p = data["strata"][key]
          is_map(p) and is_binary(p["model"]) and p["effort"] == "low" and is_binary(p["reason"])
        end)

    if valid, do: :ok, else: {:error, "invalid dated staffing matrix/provenance/mappings"}
  end

  defp validate(_), do: {:error, "invalid staffing matrix"}
end
