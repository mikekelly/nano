defmodule Nano.Flywheel.Scopes do
  @moduledoc "Canonical cooperative claims, not a filesystem sandbox. Symlinks refused."
  def normalize(scopes, repository) when is_list(scopes) do
    Enum.reduce_while(scopes, {:ok, []}, fn scope, {:ok, acc} ->
      case normalize_one(scope, repository) do
        {:ok, s} -> {:cont, {:ok, Enum.uniq([s | acc])}}
        error -> {:halt, error}
      end
    end)
  end

  def normalize(_, _), do: {:error, :invalid_scopes}

  def safe_root(path), do: if(symlink?(Path.expand(path)), do: {:error, :alias_root}, else: :ok)

  defp normalize_one(%{kind: kind, path: path}, repo)
       when kind in [:exact, :prefix] and is_binary(path) do
    cond do
      path == "" or Path.type(path) != :relative or
        Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) or
          String.contains?(path, ["\\", <<0>>]) ->
        {:error, :noncanonical_scope}

      symlink?(Path.expand(repo)) or symlink?(Path.join(repo, path)) ->
        {:error, :symlink_scope}

      hardlink?(Path.join(repo, path)) ->
        {:error, :hardlink_scope}

      true ->
        {:ok, %{kind: kind, path: path}}
    end
  end

  defp normalize_one(_, _), do: {:error, :invalid_scope}

  defp hardlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: n}} when n > 1 -> true
      _ -> false
    end
  end

  defp symlink?(path) do
    Enum.reduce_while(Path.split(path), "", fn part, acc ->
      current = if acc == "" and part == "/", do: "/", else: Path.join(acc, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, true}
        {:error, e} when e not in [:enoent, :enotdir] -> {:halt, true}
        _ -> {:cont, current}
      end
    end) == true
  end

  def overlap?(a, b) do
    # Exact ancestor paths also conflict: one cannot safely be both file and directory.
    # This is conservative ownership, not descendant coverage for an exact claim.
    a.path == b.path or String.starts_with?(b.path, a.path <> "/") or
      String.starts_with?(a.path, b.path <> "/")
  end

  def conflicts?(a, b), do: Enum.any?(a, fn x -> Enum.any?(b, &overlap?(x, &1)) end)

  def covers?(scopes, path),
    do:
      Enum.any?(scopes, fn s ->
        s.path == path or (s.kind == :prefix and String.starts_with?(path, s.path <> "/"))
      end)
end
