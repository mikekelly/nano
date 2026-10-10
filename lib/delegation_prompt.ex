defmodule Delegation.Prompt do
  @moduledoc """
  Compose the whole seed template plus reusable partials in `prompts/delegation`.
  NanoAgent renders the seed placeholders. Returned provenance hashes identify original seed
  and partial bytes and the unrendered composed template (not the rendered process prompt). Comments in partials are stripped.
  `mode: :consumer` replaces worker reporting/read-only suffix with persistent chat
  publication instructions. Optional `workspace:` must name an existing absolute
  directory with no symlink ancestors; it is not an OS sandbox. Publication protocol
  belongs in `job:`. Default worker composition is unchanged.
  Pre-reading is UTF-8, capped at 32 KiB/file and 96 KiB total; oversized files error,
  never silently truncate. SHA-256 covers exactly the included bytes.
  """
  @root Path.expand("..", __DIR__)
  def compose(opts) do
    root = opts[:prompt_root] || @root

    with {:ok, seed} <- File.read(Path.join(root, "prompts/seed.txt")),
         {:ok, parts} <-
           parts(root, ["principles" | List.wrap(opts[:flavours] || default(opts[:level]))]),
         {:ok, pre} <- preread(opts[:pre] || [], opts[:cwd] || root),
         {:ok, consumer_suffix} <- consumer_suffix(opts) do
      job =
        "\nYour level is #{opts[:level]}. Your job:\n#{opts[:job]}\n" <>
          staffing_note(opts[:staffing])

      report =
        "\nReport to #{inspect(opts[:parent])} using Delegation.report(#{inspect(opts[:name])}, result). " <>
          "Plain responses only enter your log. Use stable names, not saved pids. After reporting, idle.\n"

      isolation =
        case opts[:worktree] do
          nil ->
            "This job is read-only; no working copy was assigned. Do not edit /app.\n"

          w ->
            "Your isolated working copy is #{w.path}, branch #{w.branch}, starting revision #{w.revision}. " <>
              "Edit only owned files there. Use MIX_ENV=test for tests and MIX_BUILD_ROOT=#{w.path}/_build for other builds. Do not hot-load harness code.\n"
        end

      {report, isolation} =
        if consumer_suffix, do: consumer_suffix, else: {report, isolation}

      reading =
        Enum.map_join(pre, "\n", fn p ->
          "\nPre-read #{p.path} (SHA-256 #{p.sha256}, #{p.bytes} bytes):\n" <> p.content
        end)

      {:ok,
       %{
         prompt: seed <> "\n" <> parts.text <> job <> report <> isolation <> reading,
         provenance: %{
           seed: %{path: Path.join(root, "prompts/seed.txt"), sha256: hash(seed)},
           partials: parts.sources,
           composed_sha256:
             hash(seed <> "\n" <> parts.text <> job <> report <> isolation <> reading)
         },
         pre: Enum.map(pre, &Map.delete(&1, :content))
       }}
    end
  end

  # Consumer mode changes only the fitted suffix; seed, principles and flavours stay whole.
  defp consumer_suffix(opts) do
    case Keyword.get(opts, :mode, :worker) do
      :worker ->
        {:ok, nil}

      :consumer ->
        with {:ok, workspace} <- workspace(opts[:workspace]) do
          {:ok,
           {"\nYou are a persistent conversational bot, not a worker reporting completion to a parent. " <>
              "Plain responses only enter your log. To speak to the person, explicitly use the runtime publication protocol in your job or turn event. " <>
              "Do not invent a publication API; stay quiet when appropriate and idle between turns.\n",
            workspace}}
        end

      _ ->
        {:error, "mode must be :worker or :consumer"}
    end
  end

  defp workspace(nil), do: {:ok, "No workspace directory was assigned. Do not edit /app.\n"}

  defp workspace(path) when is_binary(path) do
    if Path.type(path) == :absolute and path == Path.expand(path) and path != "/" and
         not Regex.match?(~r/[\x00-\x1f\x7f]/, path) and safe_directory?(path) do
      {:ok,
       "Your persistent bot/session workspace directory is #{inspect(path)}. " <>
         "Keep your files there; this directory is not an OS sandbox or security boundary. " <>
         "Do not edit /app or hot-load shared harness code.\n"}
    else
      {:error,
       "workspace must be an existing absolute directory without symlinks or control characters"}
    end
  end

  defp workspace(_), do: {:error, "workspace must be an absolute directory path"}
  defp safe_directory?("/"), do: true

  defp safe_directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> safe_directory?(Path.dirname(path))
      _ -> false
    end
  end

  defp hash(text),
    do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp staffing_note(nil), do: ""

  defp staffing_note(pair),
    do:
      "\nStaffing: #{pair.model} / #{pair.effort}; #{pair.reason} Evidence: Nano.Staffing and #{pair.matrix_path}.\n"

  defp default(:exec), do: ["exec"]
  defp default(_), do: ["builder"]

  defp parts(root, names) do
    Enum.reduce_while(names, {:ok, %{text: "", sources: []}}, fn name, {:ok, acc} ->
      if is_binary(name) and name =~ ~r/^[a-z_-]+$/ do
        case File.read(Path.join(root, "prompts/delegation/#{name}.txt")) do
          {:ok, text} ->
            {:cont,
             {:ok,
              %{
                text: acc.text <> Regex.replace(~r/\{\{!.*?\}\}/s, text, "") <> "\n",
                sources:
                  acc.sources ++
                    [
                      %{
                        path: Path.join(root, "prompts/delegation/#{name}.txt"),
                        sha256: hash(text)
                      }
                    ]
              }}}

          {:error, why} ->
            {:halt, {:error, "cannot read partial #{name}: #{inspect(why)}"}}
        end
      else
        {:halt, {:error, "invalid partial name #{inspect(name)}"}}
      end
    end)
  end

  defp bounded_read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        result =
          try do
            case IO.binread(io, 32_769) do
              :eof -> {:ok, ""}
              {:error, _} = e -> e
              bytes -> {:ok, bytes}
            end
          after
            File.close(io)
          end

        result

      error ->
        error
    end
  end

  def preread(paths, cwd)
      when is_list(paths) and length(paths) <= 32 do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with true <- is_binary(path),
           absolute = Path.expand(path, cwd),
           {:ok, stat} <- File.stat(absolute),
           true <- stat.type == :regular and stat.size <= 32_768,
           {:ok, bytes} <- bounded_read(absolute),
           true <- String.valid?(bytes) and byte_size(bytes) <= 32_768,
           true <- Enum.sum(Enum.map(acc, & &1.bytes)) + byte_size(bytes) <= 98_304 do
        entry = %{
          path: absolute,
          bytes: byte_size(bytes),
          content: bytes,
          sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }

        {:cont, {:ok, acc ++ [entry]}}
      else
        why ->
          {:halt,
           {:error,
            "pre-reading #{inspect(path)} failed (regular UTF-8, 32 KiB/file, 96 KiB total required): #{inspect(why)}"}}
      end
    end)
  end

  def preread(_, _), do: {:error, "pre must be a list of at most 32 file paths"}
end
