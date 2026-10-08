defmodule SafetyNet do
  @moduledoc """
  Discover and attest the external recovery supervisor. It is **not enabled** merely by
  loading this module. See `docs/safety-net.md` for isolated tests and installation.

  `status/0` reads metadata only, never credentials. `served/0` is called by the model
  success path (or explicitly after verifying a real successful response) to permit
  known-good promotion. A heartbeat alone cannot prove model access.

  `write_credential/2` replaces the seed's atomic credential writer when integrated:
  with the net installed it durably backs up new bytes before replacing the original,
  serialized against restoration. Without installation it is a private atomic write.
  Intentional logout uses `forget_credential/1`; intentional empty settings saved through
  this writer suppress restoration until a later nonempty save.
  """

  @doc "Safe metadata including installation and last recovery; stale status is not proof of liveness."
  def status do
    home = home()

    %{
      installed: File.regular?(Path.join(home, "runtime/supervisor.py")),
      disabled: File.exists?(Path.join(home, "disabled")),
      lockup_protection:
        if(Application.get_env(:nano, :test_dir) == nil and System.get_env("SAFETY_NET_SESSION"),
          do: :configured_check_monitor_liveness,
          else: :inactive_for_current_node
        ),
      container_restart_policy: :unknown_external_configuration_required,
      status: json(Path.join(home, "status.json")),
      monitor: json(Path.join(home, "monitor.json")),
      liveness: :unknown_check_monitor_timestamp,
      recovery: json(Path.join(home, "recovery.json")),
      credentials:
        Map.new(["settings.json", "chatgpt_auth.json"], fn name ->
          {name,
           %{
             backup: File.regular?(Path.join([home, "credentials", name])),
             pending: File.regular?(Path.join([home, "pending", name])),
             forgotten: File.regular?(Path.join([home, "forgotten", name]))
           }}
        end),
      reports: Path.join(home, "reports.jsonl")
    }
  end

  @doc "Attest a successful model response in this boot session; no-op when unprotected."
  def served do
    case {Application.get_env(:nano, :test_dir), System.get_env("SAFETY_NET_SESSION"),
          System.get_env("SAFETY_NET_TOKEN")} do
      {nil, session, token} when is_binary(session) and is_binary(token) ->
        atomic(Path.join(session, "served"), token)

      _ ->
        :ok
    end
  end

  @doc "Backup currently valid credentials synchronously; prefer write_credential/2 for rotation safety."
  def backup_credentials do
    command("backup", [])
  end

  @doc "Private, atomic credential save with write-through backup when installed. Never logs bytes."
  def write_credential(path, bytes) when is_binary(path) and is_binary(bytes) do
    # Python's stdin is supplied through a private staging file, never process arguments.
    # The external transaction locks backup and target replacement together.
    if File.regular?(Path.join(home(), "config.json")) and
         not File.exists?(Path.join(home(), "disabled")) do
      staging = path <> ".safety-" <> Base.encode16(:crypto.strong_rand_bytes(8))

      with :ok <- atomic(staging, bytes) do
        case command("write", ["--input", staging, "--target", Path.expand(path)]) do
          :ok ->
            File.rm(staging)
            :ok

          {:error, _} = error ->
            # Preserve new token bytes privately even if the installed writer disappeared.
            # A live monitor reloads after replaying any already-durable journal.
            atomic(Path.join(home(), "reload_requested"), "credential persistence failed\n")
            error
        end
      end
    else
      atomic(path, bytes)
    end
  end

  @doc "Intentionally remove a credential and suppress restoration until the next successful save."
  def forget_credential(path) do
    if File.regular?(Path.join(home(), "config.json")) and
         not File.exists?(Path.join(home(), "disabled")) do
      case command("forget", ["--target", Path.expand(path)]) do
        :ok ->
          :ok

        {:error, _} = error ->
          atomic(Path.join(home(), "reload_requested"), "credential removal failed\n")
          error
      end
    else
      case File.rm(path) do
        {:error, :enoent} -> :ok
        result -> result
      end
    end
  end

  defp command(action, args) do
    script = Path.join(home(), "runtime/supervisor.py")

    if File.regular?(script) do
      case System.cmd("timeout", ["10s", "python3", script, "--home", home(), action | args],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {_, _} -> {:error, :safety_transaction_failed}
      end
    else
      if action == "backup", do: :ok, else: {:error, :safety_runtime_unavailable}
    end
  rescue
    _ -> {:error, :safety_runtime_unavailable}
  end

  defp atomic(path, bytes) do
    tmp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8))

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, io} <- File.open(tmp, [:write, :binary, :exclusive]) do
        result =
          with :ok <- File.chmod(tmp, 0o600),
               :ok <- IO.binwrite(io, bytes),
               :ok <- :file.sync(io),
               :ok <- File.close(io),
               do: File.rename(tmp, path)

        File.close(io)
        result
      end
    after
      File.rm(tmp)
    end
  end

  # The seed isolates test state even when run inside a protected production container.
  defp home do
    case Application.get_env(:nano, :test_dir) do
      nil -> System.get_env("SAFETY_NET_HOME", "/data/safety-net")
      directory -> Path.join(directory, "safety-net")
    end
  end

  defp json(path) do
    with {:ok, bytes} <- File.read(path), {:ok, data} <- Jason.decode(bytes), do: data
  end
end
