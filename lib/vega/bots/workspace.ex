defmodule Vega.Bots.Workspace do
  @moduledoc "Stable identity computer/session directories. Filesystem organization and context separation, NOT a security sandbox: bots share a privileged BEAM/container."
  def identity(root, bot) when is_binary(bot) do
    if Regex.match?(~r/\A[0-9a-f]{20}\z/, bot),
      do: {:ok, Path.join([root, "bot-computers", bot])},
      else: {:error, :invalid_bot_id}
  end

  def identity(_, _), do: {:error, :invalid_bot_id}

  def ensure(root, bot, session \\ nil) do
    with {:ok, identity} <- identity(root, bot),
         {:ok, session_path} <- session_path(identity, session),
         :ok <- File.mkdir_p(identity),
         :ok <- if(session_path, do: File.mkdir_p(session_path), else: :ok) do
      {:ok, %{"identity" => identity, "session" => session_path}}
    end
  end

  defp session_path(_, nil), do: {:ok, nil}

  defp session_path(identity, sid) when is_binary(sid) do
    if Regex.match?(~r/\A[0-9a-f]{20}\z/, sid),
      do: {:ok, Path.join([identity, "sessions", sid])},
      else: {:error, :invalid_session_id}
  end

  defp session_path(_, _), do: {:error, :invalid_session_id}
end
