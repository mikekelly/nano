defmodule Nano.Safety do
  @moduledoc """
  Outside-checkout recovery status and credential write-through copies.
  `status/0` reports the independent OS watchdog (including stale/off state).
  `health/0` is its loopback probe. Promotion requires a successful model reply.
  See `scripts/safety/README.md`. Loading this module starts no watchdog.
  """
  def root, do: System.get_env("NANO_SAFETY_DIR") || "/data/safety"

  def health,
    do: %{
      responsive: true,
      boot: System.pid(),
      model_served: :persistent_term.get({__MODULE__, :served}, false) and code_matches_disk?()
    }

  # A hot-loaded module from another checkout is not evidence that this source booted.
  # Check loaded code against its compiled file, including its original source location.
  defp code_matches_disk? do
    source_root = Path.join(File.cwd!(), "lib") <> "/"

    for {module, beam} <- :code.all_loaded(),
        String.starts_with?(Atom.to_string(module), "Elixir.Nano") and module != Nano.MixProject,
        reduce: true do
      valid ->
        matches =
          with true <- is_list(beam) and beam != [],
               {:ok, {^module, md5}} <- :beam_lib.md5(beam),
               true <- md5 == module.module_info(:md5),
               source when is_list(source) <- module.module_info(:compile)[:source] do
            String.starts_with?(List.to_string(source), source_root)
          else
            _ -> false
          end

        valid and matches
    end
  rescue
    _ -> false
  end

  def model_result({:ok, _} = result) do
    :persistent_term.put({__MODULE__, :served}, true)
    result
  end

  def model_result(result), do: result
  @doc "Secret-free status; stale or disabled watchdogs never count as protection."
  def status(root \\ root()) do
    case File.read(Path.join(root, "status.json")) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, status} when is_map(status) ->
            updated = Map.get(status, "updated", 0)
            age = if is_integer(updated), do: System.system_time(:second) - updated, else: 30
            fresh = age >= 0 and age < 30

            Map.put(
              status,
              "protected",
              fresh and to_string(status["child_pid"]) == System.pid() and
                status["state"] == "watching" and
                not File.exists?(Path.join(root, "disabled"))
            )

          _ ->
            %{protected: false, state: "invalid_status"}
        end

      _ ->
        if File.exists?(Path.join(root, "config.json")),
          do: %{protected: false, state: "pending_restart"},
          else: %{protected: false, state: "not_installed"}
    end
  end

  @doc "Copy credentials synchronously before publishing a write. No-op unless installed."
  def backup(path, bytes, root \\ root()) do
    if File.exists?(Path.join(root, "config.json")) and valid_copy?(bytes) do
      target = Path.join([root, "credentials", Path.basename(path)])
      bytes = preserve_missing_secrets(target, bytes)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.chmod(Path.dirname(target), 0o700),
           :ok <- atomic(target, bytes),
           do: :ok
    else
      :ok
    end
  end

  # Removing one provider key must not erase the only recovery copy. A watcher
  # merges only lost secrets back, never overwriting newer unrelated settings.
  defp preserve_missing_secrets(target, bytes) do
    if Path.basename(target) == "settings.json" do
      with {:ok, old_bytes} <- File.read(target),
           {:ok, old} when is_map(old) <- Jason.decode(old_bytes),
           {:ok, new} when is_map(new) <- Jason.decode(bytes) do
        old
        |> Enum.reduce(new, fn {key, value}, acc ->
          secret = key == "openrouter_api_key" or String.upcase(key) == key

          if secret and is_binary(value) and value != "" and Map.get(acc, key) in [nil, ""],
            do: Map.put(acc, key, value),
            else: acc
        end)
        |> Jason.encode!()
      else
        _ -> bytes
      end
    else
      bytes
    end
  end

  defp sync_directory(path) do
    with {:ok, fd} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      result = :file.sync(fd)
      :file.close(fd)
      result
    end
  end

  defp valid_copy?(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> map_size(map) > 0
      _ -> false
    end
  end

  defp atomic(target, bytes) do
    tmp = target <> "." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp, "", [:exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, bytes, [:sync]),
         :ok <- File.rename(tmp, target),
         :ok <- sync_directory(Path.dirname(target)),
         do: :ok
  end
end
