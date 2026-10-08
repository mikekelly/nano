defmodule SeedSafety do
  @moduledoc """
  Entry point for the external safety net. `status/0` reads its last secret-free
  event; `attest/0` certifies the current supervised boot after a successful model
  response (source only). `attest(provider: "openrouter")` additionally validates
  credential specs explicitly tagged provider="openrouter". Never pass a provider
  unless the successful request used those configured credentials.
  `reject/3` marks the exact credential that received a definitive authentication
  rejection, never a timeout/rate limit. A newer replacement will not be reverted.

  Installation (integration owner): install Python 3; copy bin/seed-watchdog to
  /opt/seed-safety/watchdog (0755); run it as container entrypoint under init with
  a root-only config outside /app. Keep original bin/start as its child command.
  Configure probe as an independent bounded RPC (not a heartbeat inside BEAM),
  e.g. an installed copy of bin/rpc calling `Process.alive?(Process.whereis(Nano.Supervisor))`
  and exiting nonzero on false. Do not trust RPC exit zero without checking result.
  State defaults to /data/seed-safety and must be outside /app. Configure explicit
  JSON credential files/keys for settings.json openrouter_api_key/operator keys.
  ChatGPT adapter config uses kind="chatgpt", provider="chatgpt" and path
  /data/state/chatgpt_auth.json; no keys list. It validates string access/refresh
  tokens and account_id, integer expires_at, optional id_token/email/plan, backs
  up all metadata, and restores coherent pairs. Incomplete newer rotated pairs
  are preserved and flagged rather than mixed with a stale backup.

  Recovery journals live at state/events.jsonl and status.json, with displaced
  work in source-evidence-* and secrets in credentials-evidence-* (root only).
  Rollback excludes .git, deps, _build; git status then shows restored working
  tree against current HEAD. Evidence preserves untracked/uncommitted sources.
  No protection against host loss, deleted volumes, or malicious root processes.
  Passive live deployment: install bin/seed-safety-monitor.json as a root-only
  /opt/seed-safety/monitor.json and run installed watchdog with that config. It
  only probes and logs; status explicitly says protected=false. This mode never
  starts/stops the existing BEAM, restores credentials or changes source. Active
  protection requires the watchdog to be the next container entrypoint. Template
  bin/seed-safety-config.json preserves /app/bin/start as the child command.
  At most two launch snapshots are retained by default (keep_launches config).
  Displaced source/credential evidence is never automatically deleted; operators
  must archive/prune it explicitly. Monitor journal also needs log rotation.
  This module does not start anything or alter the shared node on load.
  """
  def status(dir \\ directory()) do
    case File.read(Path.join(dir, "status.json")) do
      {:ok, json} -> Jason.decode(json)
      {:error, :enoent} -> {:ok, %{"protected" => false, "event" => "not_installed"}}
      error -> error
    end
  end

  @doc "Certify only after a successful model response; no credentials enter this file."
  def attest(opts \\ []) do
    dir = if is_binary(opts), do: opts, else: Keyword.get(opts, :dir, directory())
    providers = if is_list(opts), do: List.wrap(Keyword.get(opts, :provider, [])), else: []

    case System.get_env("SEED_SAFETY_BOOT") do
      nil ->
        {:error, :not_supervised}

      boot ->
        write(dir, "attestation.json", %{
          boot: boot,
          time: System.system_time(:nanosecond),
          providers: providers
        })
    end
  end

  @doc "Mark a definitively rejected string credential; callers must not log its value."
  def reject(path, key, value, dir \\ directory()) when is_binary(value) do
    file = Path.join(dir, "rejected.json")

    current =
      case File.read(file) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, %{} = map} -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    hash = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

    updated =
      Map.update(
        current,
        Path.expand(path),
        %{to_string(key) => hash},
        &Map.put(&1, to_string(key), hash)
      )

    write(dir, "rejected.json", updated)
  end

  @doc """
  Mark a definitively rejected ChatGPT token generation. Both exact request access
  token and its corresponding refresh token guard a concurrently rotated pair.
  Never call on rate limits/timeouts or mere expiry: let Auth refresh normally.
  Revoked or used refresh tokens may be unrecoverable even from a backup.
  """
  def reject_chatgpt(path, access, refresh, dir \\ directory())
      when is_binary(access) and is_binary(refresh) do
    reject(path, "@chatgpt", access <> <<0>> <> refresh, dir)
  end

  defp directory do
    case Application.get_env(:nano, :test_dir) do
      path when is_binary(path) -> Path.join(path, "seed-safety")
      _ -> System.get_env("SEED_SAFETY_DIR", "/data/seed-safety")
    end
  end

  defp write(dir, name, data) do
    path = Path.join(dir, name)
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive]))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, io} <- File.open(tmp, [:write, :exclusive]) do
      result =
        with :ok <- File.chmod(tmp, 0o600),
             :ok <- IO.binwrite(io, Jason.encode!(data)),
             :ok <- :file.sync(io),
             do: :ok

      File.close(io)
      result = if result == :ok, do: File.rename(tmp, path), else: result
      File.rm(tmp)
      result
    end
  end
end
