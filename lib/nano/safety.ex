defmodule Nano.Safety do
  @moduledoc """
  Outside-checkout recovery status and credential write-through copies.
  `status/0` reports the independent OS watchdog (including stale/off state).
  `health/0` is its loopback probe. Promotion requires a successful model reply.
  Root defaults to `/data/safety`; :nano/:safety_dir takes precedence over
  NANO_SAFETY_DIR so disposable test VMs cannot inherit production stores.
  See `scripts/safety/README.md`. Loading this module starts no watchdog.
  """
  require Logger

  def root,
    do:
      Application.get_env(:nano, :safety_dir) || System.get_env("NANO_SAFETY_DIR") ||
        "/data/safety"

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

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.chmod(Path.dirname(target), 0o700),
           :ok <- atomic(target, bytes),
           do: :ok
    else
      :ok
    end
  end

  # Capability checked by the outside-checkout runner before any fallback launch.
  @credential_intent_schema 1
  @credential_intent_lock 1
  @noncredential_settings_schema 1
  @maintenance "credential authority unavailable or blocked; stop credential writers and reconcile in maintenance"

  @doc "Read protected credential authority. Never log the returned private values."
  def credential_read(file) do
    serialized(fn ->
      with {:ok, intent} <- authority(),
           false <- File.exists?(barrier()) do
        {:ok, materialize(file, read_primary(file), intent), generation(intent, file)}
      else
        _ -> {:error, @maintenance}
      end
    end)
  end

  @doc "Explicit login/set or generation-conditional refresh; persisted before publication."
  def credential_write(file, values, expected \\ :explicit) when is_map(values) do
    serialized(fn ->
      with {:ok, intent} <- authority(),
           false <- File.exists?(barrier()),
           :ok <- eligible(intent, file, expected),
           {:ok, next} <- mutate_intent(intent, file, values, expected),
           :ok <- commit_credentials(file, values, next) do
        {:ok, generation(next, file)}
      else
        {:error, :stale} -> {:error, :stale}
        _ -> {:error, @maintenance}
      end
    end)
  end

  @doc "Commit invalidation before removing the primary or clearing a backup."
  def credential_invalidate(file, expected \\ :explicit),
    do: credential_write(file, %{}, expected)

  @doc "Offline only: complete latest existing protected intent; never reconstruct lost authority. No values returned."
  def reconcile_credentials do
    serialized(fn ->
      result =
        case authority() do
          {:ok, intent} -> {:ok, intent}
          {:error, :enoent} -> {:error, @maintenance}
          _ -> {:error, @maintenance}
        end

      with {:ok, intent} <- result,
           :ok <- ensure_credentials_dir(),
           :ok <- atomic(history_marker(), "1\n"),
           :ok <- atomic(barrier(), ~s({"schema_version":1})),
           :ok <- atomic(intent_path(), Jason.encode!(intent)),
           :ok <- reconcile_files(intent),
           :ok <- clear_barrier() do
        :ok
      else
        _ -> {:error, @maintenance}
      end
    end)
  end

  @doc "Explicit brand-new installation provisioning; operator must attest no prior authority existed."
  def provision_new_credentials(:new_installation) do
    serialized(fn ->
      paths = [
        history_marker(),
        intent_path(),
        barrier(),
        mirror(),
        primary("settings.json"),
        primary("chatgpt_auth.json"),
        copy("settings.json"),
        copy("chatgpt_auth.json")
      ]

      if Enum.any?(paths, &File.exists?/1),
        do: {:error, @maintenance},
        else: establish(%{"schema_version" => 1, "revision" => 0, "entries" => %{}})
    end)
  end

  def provision_new_credentials(_), do: {:error, @maintenance}

  @doc "Offline legacy migration only, not lost-authority repair; requires explicit legacy attestation."
  def reconcile_legacy_credentials(:legacy_installation) do
    serialized(fn ->
      if Enum.any?([history_marker(), intent_path(), barrier(), mirror()], &File.exists?/1) do
        {:error, @maintenance}
      else
        with {:ok, intent} <- legacy_intent(), do: establish(intent)
      end
    end)
  end

  def reconcile_legacy_credentials(_), do: {:error, @maintenance}

  defp establish(intent) do
    with :ok <- ensure_credentials_dir(),
         :ok <- atomic(history_marker(), "1\n"),
         :ok <- atomic(barrier(), ~s({"schema_version":1})),
         :ok <- atomic(intent_path(), Jason.encode!(intent)),
         :ok <- reconcile_files(intent),
         :ok <- clear_barrier(),
         do: :ok
  end

  @doc false
  def noncredential_settings_write(values) do
    # Separate document: no credential-bearing primary/backup is touched when
    # protected storage is unavailable. Full snapshot preserves deletion intent.
    :global.trans({{__MODULE__, :noncredential_settings}, self()}, fn ->
      with :ok <- noncredential_write_ready(),
           :ok <- File.mkdir_p(Path.dirname(noncredential_path())),
           :ok <-
             atomic(
               noncredential_path(),
               Jason.encode!(%{
                 "schema_version" => @noncredential_settings_schema,
                 "values" => nonsecret_values(values)
               })
             ),
           do: :ok
    end)
  end

  @doc false
  def prepare_noncredential_upgrade(values) do
    :global.trans({{__MODULE__, :noncredential_settings}, self()}, fn ->
      case noncredential_document() do
        {:error, :enoent} ->
          # Parent suspended the old owner. Its nonsecret memory and legacy
          # primary must agree before establishing the new durable snapshot.
          if nonsecret_values(values) == nonsecret_values(read_map(primary("settings.json"))) do
            with :ok <- File.mkdir_p(Path.dirname(noncredential_path())),
                 :ok <-
                   atomic(
                     noncredential_path(),
                     Jason.encode!(%{
                       "schema_version" => @noncredential_settings_schema,
                       "values" => nonsecret_values(values)
                     })
                   ),
                 do: {:ok, nonsecret_values(values)}
          else
            {:error, :noncredential_settings_maintenance}
          end

        {:ok, ordinary} ->
          {:ok, ordinary}

        _ ->
          {:error, :noncredential_settings_maintenance}
      end
    end)
  end

  defp noncredential_write_ready do
    case noncredential_document() do
      {:ok, _} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :noncredential_settings_maintenance}
    end
  end

  defp noncredential_document do
    with {:ok, bytes} <- File.read(noncredential_path()),
         {:ok, %{"schema_version" => @noncredential_settings_schema, "values" => values}}
         when is_map(values) <- Jason.decode(bytes),
         true <-
           Enum.all?(values, fn {key, _} -> nonsecret_key?(key) and canonical_nonsecret?(key) end),
         do: {:ok, values},
         else: (
           {:error, :enoent} -> {:error, :enoent}
           _ -> {:error, :noncredential_settings_maintenance}
         )
  end

  @doc false
  def noncredential_settings_read(legacy \\ nil) do
    legacy = legacy || read_map(primary("settings.json"))

    case noncredential_document() do
      {:error, :enoent} -> nonsecret_values(legacy)
      {:ok, values} -> values
      _ -> damaged_noncredentials()
    end
  end

  defp damaged_noncredentials do
    Logger.warning("noncredential settings document unavailable; using nonsecret defaults")
    %{}
  end

  defp nonsecret_key?(key) do
    case Nano.Settings.key(key) do
      {:ok, canonical} when is_atom(canonical) and canonical != :openrouter_api_key -> true
      _ -> false
    end
  end

  defp canonical_nonsecret?(key) do
    case Nano.Settings.key(key) do
      {:ok, canonical} -> key == to_string(canonical)
      _ -> false
    end
  end

  defp nonsecret_values(values) do
    values |> normalize_settings() |> Map.filter(fn {key, _} -> nonsecret_key?(key) end)
  end

  defp noncredential_path, do: primary("settings-noncredentials-v1.json")

  # The stable lock inode is shared with the external Python watchdog. A port
  # holder releases the OS lock on stdin EOF, including owner/VM death.
  defp serialized(fun) do
    :global.trans({{__MODULE__, :credential_intent}, self()}, fn ->
      with :ok <- ensure_credentials_dir(),
           flock when is_binary(flock) <- System.find_executable("flock") do
        port =
          Port.open({:spawn_executable, flock}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:args,
             [
               "-x",
               "-w",
               "5",
               Path.join([root(), "credentials", "intent-v1.lock"]),
               "/bin/sh",
               "-c",
               "printf 'locked\\n'; read release"
             ]}
          ])

        try do
          receive do
            {^port, {:data, "locked\n"}} -> fun.()
            {^port, {:exit_status, _}} -> {:error, @maintenance}
          after
            6_000 -> {:error, @maintenance}
          end
        after
          # Sending a newline lets the holder exit normally; close also supplies
          # EOF if the caller exits while holding it. Never unlink the lock inode.
          if Port.info(port) do
            Port.command(port, "release\n")
            Port.close(port)
          end
        end
      else
        _ -> {:error, @maintenance}
      end
    end)
  rescue
    _ -> {:error, @maintenance}
  end

  defp intent_path, do: Path.join([root(), "credentials", "intent-v1.json"])
  defp history_marker, do: Path.join([root(), "credentials", "intent-required-v1"])
  defp barrier, do: Path.join([root(), "credentials", "intent-blocked-v1.json"])
  defp primary(file), do: Path.join(Application.fetch_env!(:nano, :state_dir), file)
  defp copy(file), do: Path.join([root(), "credentials", file])
  defp mirror, do: primary("credential-intent-v1.json")

  defp authority do
    with {:ok, bytes} <- File.read(intent_path()),
         {:ok,
          %{
            "schema_version" => @credential_intent_schema,
            "revision" => revision,
            "entries" => entries
          } = intent} <- Jason.decode(bytes),
         true <- is_integer(revision) and revision >= 0 and is_map(entries),
         true <- Enum.all?(entries, fn {key, entry} -> valid_entry?(key, entry, revision) end) do
      {:ok, intent}
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, @maintenance}
    end
  end

  defp valid_entry?(key, %{"state" => "invalidated", "version" => v} = e, rev),
    do: valid_id?(key) and is_integer(v) and v > 0 and v <= rev and not Map.has_key?(e, "value")

  defp valid_entry?(
         key,
         %{"state" => "enabled", "version" => v, "generation" => g, "value" => value},
         rev
       ),
       do:
         valid_id?(key) and is_integer(v) and is_integer(g) and g > 0 and g <= v and v <= rev and
           if(key == "chatgpt_auth.json",
             do: valid_auth?(value),
             else: is_binary(value)
           )

  defp valid_entry?(_, _, _), do: false
  defp valid_id?("chatgpt_auth.json"), do: true

  defp valid_id?("settings/" <> key),
    do: secret_key?(key) and (key == "openrouter_api_key" or key == String.upcase(key))

  defp valid_id?(_), do: false

  defp valid_auth?(%{"access_token" => a, "refresh_token" => r}),
    do: is_binary(a) and a != "" and is_binary(r) and r != ""

  defp valid_auth?(_), do: false

  defp secret_key?(key) do
    case Nano.Settings.key(key) do
      {:ok, :openrouter_api_key} -> true
      {:ok, canonical} when is_binary(canonical) -> true
      _ -> false
    end
  end

  defp normalize_settings(values) do
    Map.new(values, fn {key, value} ->
      case Nano.Settings.key(key) do
        {:ok, canonical} -> {to_string(canonical), value}
        _ -> {to_string(key), value}
      end
    end)
  end

  defp read_primary("settings.json" = file) do
    case File.read(primary(file)) do
      {:error, :enoent} ->
        %{}

      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, map} when is_map(map) ->
            map

          _ ->
            Logger.warning("ignoring damaged primary settings; protected credentials retained")
            %{}
        end

      _ ->
        Logger.warning("ignoring unreadable primary settings; protected credentials retained")
        %{}
    end
  end

  defp read_primary(file), do: read_map(primary(file))

  defp read_map(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(bytes),
         do: map,
         else: (_ -> %{})
  end

  defp generation(intent, file), do: get_in(intent, ["entries", file, "generation"])
  defp eligible(_, _, :explicit), do: :ok

  defp eligible(_, "settings.json", {:setting, key}),
    do: if(secret_key?(key), do: :ok, else: {:error, :stale})

  defp eligible(intent, file, expected) when is_integer(expected) do
    if get_in(intent, ["entries", file, "state"]) == "enabled" and
         generation(intent, file) == expected, do: :ok, else: {:error, :stale}
  end

  defp eligible(_, _, _), do: {:error, :stale}

  defp mutate_intent(intent, "chatgpt_auth.json" = file, values, expected) do
    if values == %{} or valid_auth?(values) do
      {:ok, put_entry(intent, file, if(values == %{}, do: nil, else: values), expected)}
    else
      {:error, :invalid_credentials}
    end
  end

  defp mutate_intent(intent, "settings.json", values, {:setting, key}) do
    values = normalize_settings(values)
    value = Map.get(values, key)

    if value == nil or is_binary(value),
      do: {:ok, put_entry(intent, "settings/" <> key, value, :explicit)},
      else: {:error, :invalid_credentials}
  end

  defp mutate_intent(intent, "settings.json", values, :explicit) do
    values = normalize_settings(values)

    keys =
      (Map.keys(values) ++ for("settings/" <> key <- Map.keys(intent["entries"]), do: key))
      |> Enum.uniq()

    if Enum.any?(values, fn {key, value} -> secret_key?(key) and not is_binary(value) end) do
      {:error, :invalid_credentials}
    else
      {:ok,
       Enum.reduce(keys, intent, fn key, acc ->
         if secret_key?(key) do
           value = Map.get(values, key)
           old = get_in(acc, ["entries", "settings/" <> key, "value"])
           if old == value, do: acc, else: put_entry(acc, "settings/" <> key, value, :explicit)
         else
           acc
         end
       end)}
    end
  end

  defp mutate_intent(_, _, _, _), do: {:error, :invalid_credentials}

  defp put_entry(intent, key, value, expected) do
    v = intent["revision"] + 1

    entry =
      if value == nil,
        do: %{"state" => "invalidated", "version" => v},
        else: %{
          "state" => "enabled",
          "version" => v,
          "generation" => if(expected == :explicit, do: v, else: expected),
          "value" => value
        }

    intent |> Map.put("revision", v) |> put_in(["entries", key], entry)
  end

  defp materialize("chatgpt_auth.json", _, intent),
    do: get_in(intent, ["entries", "chatgpt_auth.json", "value"]) || %{}

  defp materialize("settings.json", values, intent) do
    values = normalize_settings(values)
    values = noncredential_settings_read(values)

    Enum.reduce(intent["entries"], values, fn
      {"settings/" <> key, %{"state" => "enabled", "value" => value}}, acc ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  # Disposable fault-rehearsal seam: stages only, never credentials or paths.
  defp checkpoint(stage) do
    case Application.get_env(:nano, :credential_intent_checkpoint) do
      fun when is_function(fun, 1) -> fun.(stage)
      _ -> :ok
    end
  end

  defp commit_credentials(file, values, intent) do
    with :ok <- ensure_credentials_dir(),
         :ok <- atomic(history_marker(), "1\n"),
         :ok <- atomic(barrier(), ~s({"schema_version":1})),
         :ok <- checkpoint(:before_intent),
         :ok <- atomic(intent_path(), Jason.encode!(intent)),
         :ok <- checkpoint(:after_intent),
         :ok <-
           write_materialized(file, Map.new(values, fn {k, v} -> {to_string(k), v} end), intent),
         :ok <- write_mirror(intent),
         :ok <- clear_barrier(),
         do: :ok
  end

  defp ensure_credentials_dir do
    with :ok <- File.mkdir_p(Path.dirname(intent_path())),
         :ok <- File.chmod(Path.dirname(intent_path()), 0o700),
         :ok <- sync_directory(Path.dirname(root())),
         :ok <- sync_directory(root()),
         do: :ok
  end

  defp write_mirror(intent) do
    with :ok <- File.mkdir_p(Path.dirname(mirror())), do: atomic(mirror(), Jason.encode!(intent))
  end

  defp write_materialized(file, values, intent) do
    map = materialize(file, values, intent)

    with :ok <- File.mkdir_p(Path.dirname(primary(file))),
         :ok <- atomic(copy(file), Jason.encode!(map)),
         :ok <- checkpoint(:after_backup),
         :ok <-
           if(file == "chatgpt_auth.json" and map == %{},
             do: remove_primary(file),
             else: atomic(primary(file), Jason.encode!(map))
           ),
         :ok <- checkpoint(:after_primary),
         do: :ok
  end

  defp remove_primary(file) do
    case File.rm(primary(file)) do
      :ok -> sync_directory(Path.dirname(primary(file)))
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp clear_barrier do
    with :ok <- File.rm(barrier()), do: sync_directory(Path.dirname(barrier()))
  end

  defp reconcile_files(intent) do
    with :ok <- write_materialized("settings.json", read_primary("settings.json"), intent),
         :ok <- write_materialized("chatgpt_auth.json", %{}, intent),
         :ok <- write_mirror(intent),
         do: :ok
  end

  defp legacy_map(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(bytes),
         do: {:ok, map},
         else: (
           {:error, :enoent} -> {:ok, %{}}
           _ -> {:error, :invalid_legacy}
         )
  end

  defp unambiguous_settings?(values) do
    values
    |> Enum.group_by(
      fn {key, _} ->
        case Nano.Settings.key(key) do
          {:ok, canonical} -> to_string(canonical)
          _ -> key
        end
      end,
      fn {_, value} -> value end
    )
    |> Enum.all?(fn {_, values} -> length(Enum.uniq(values)) == 1 end)
  end

  defp legacy_intent do
    # No backup-only enablement. Preserve all original bytes before committing authority.
    files = ["settings.json", "chatgpt_auth.json"]

    with true <-
           Enum.all?(files, fn file ->
             current = legacy_map(primary(file))
             backup = legacy_map(copy(file))

             match?({:ok, _}, current) and match?({:ok, _}, backup) and
               (backup == {:ok, %{}} or (current != {:ok, %{}} and current == backup))
           end),
         true <- unambiguous_settings?(read_map(primary("settings.json"))),
         :ok <- preserve_legacy(files ++ ["settings-noncredentials-v1.json"]) do
      empty = %{"schema_version" => 1, "revision" => 0, "entries" => %{}}

      with {:ok, settings} <-
             mutate_intent(empty, "settings.json", read_map(primary("settings.json")), :explicit),
           {:ok, auth} <-
             mutate_intent(
               settings,
               "chatgpt_auth.json",
               read_map(primary("chatgpt_auth.json")),
               :explicit
             ),
           do: {:ok, auth}
    else
      _ -> {:error, @maintenance}
    end
  end

  defp preserve_legacy(files) do
    evidence =
      Path.join([
        root(),
        "credentials",
        "legacy-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      ])

    with :ok <- File.mkdir_p(evidence), :ok <- File.chmod(evidence, 0o700) do
      Enum.reduce_while(
        for(file <- files, location <- [:primary, :backup], do: {file, location}),
        :ok,
        fn {file, location}, _ ->
          path = if location == :primary, do: primary(file), else: copy(file)

          case File.read(path) do
            {:ok, bytes} ->
              case atomic(Path.join(evidence, "#{location}-#{file}"), bytes) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            {:error, :enoent} ->
              {:cont, :ok}

            error ->
              {:halt, error}
          end
        end
      )
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
