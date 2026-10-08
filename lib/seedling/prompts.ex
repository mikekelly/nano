defmodule Seedling.Prompts do
  @moduledoc """
  Lean, strict Mustache-like prompt composition (not full Mustache).

      Seedling.Prompts.render("{{>role}}\nJob: {{job}}",
        %{"job" => "Review only"}, partials: %{"role" => "Reviewer"})

  Supports `{{variable}}`, `{{>partial}}` and removed `{{! comments }}`.
  No HTML escaping, sections, evaluation or recursive variable expansion.
  Unknown names and partial cycles are errors, not silently dropped context.
  `:preserve` explicitly permits unresolved harness runtime variables.
  Limits: 32 levels and 16 KB rendered output by default. Comments are stripped
  from *templates*, never from variable data. All failures are actionable values.
  """

  @runtime ~w(pid name node otp_release elixir_version os_user os network_policy max_turns max_tokens max_context result_max_bytes)
  def runtime_variables, do: @runtime

  @doc """
  Compose node facts followed by selected file-backed partials, without imposing a
  report contract. For example, a long-lived bot can use:

      Seedling.Prompts.compose(["operating", "orientation", "bot"], %{},
        partials: %{"bot" => "Bot identity and APIs..."})

  Options: `:facts_file`, `:prompt_root`, `:partials` (overrides/additions),
  `:max_bytes` (16 KB), `:preserve` (defaults to runtime_variables/0).
  File partial names use letters/digits/underscore/dot/hyphen, never paths.
  Nested partials are loaded automatically from the same root; comments removed.
  Unknown variables fail. Variable data is not re-expanded by this renderer, but
  the seed later replaces runtime placeholders: avoid literal runtime tags in data.
  """
  def compose(parts, vars \\ %{}, opts \\ []) do
    if is_list(parts) and Enum.all?(parts, &part_name?/1) and Keyword.keyword?(opts) do
      cap = Keyword.get(opts, :max_bytes, 16_000)
      dir = Keyword.get(opts, :prompt_root, Path.expand("../../priv/seedling/prompts", __DIR__))

      facts_file =
        Keyword.get(opts, :facts_file, Path.expand("../../priv/system_prompt.txt", __DIR__))

      overrides = Keyword.get(opts, :partials, %{})

      if is_integer(cap) and cap > 0 and is_binary(dir) and text_map?(overrides) do
        with {:ok, facts} <- read_template(facts_file, cap),
             {:ok, partials} <- load_parts(parts ++ references(facts), dir, overrides, cap) do
          template = facts <> "\n" <> Enum.map_join(parts, "\n", &"{{>#{&1}}}")

          render(
            template,
            vars,
            Keyword.merge(opts,
              partials: partials,
              preserve: Keyword.get(opts, :preserve, runtime_variables())
            )
          )
        end
      else
        error(
          :invalid_options,
          "Give a positive max_bytes, prompt_root path and string-keyed partials text map."
        )
      end
    else
      error(:invalid_options, "Give a list of simple partial names and keyword options.")
    end
  end

  defp part_name?(name),
    do: is_binary(name) and Regex.match?(~r/^[\w.-]+$/, name) and name not in [".", ".."]

  defp read_template(path, cap) when is_binary(path) do
    case Seedling.Files.read(path, limit: 5000, max_bytes: cap) do
      {:ok, %{truncated: false, text: text}} ->
        {:ok, text}

      {:ok, _} ->
        error(
          :prompt_too_large,
          "Template #{path} exceeds #{cap} bytes/5000 lines; keep partials lean."
        )

      {:error, %{reason: :line_too_long, message: message}} ->
        error(:prompt_too_large, message)

      {:error, _} = error ->
        error
    end
  end

  defp read_template(_, _),
    do: error(:invalid_options, "facts_file must be a readable text path.")

  defp references(text),
    do: Regex.scan(~r/\{\{>\s*([^}]+?)\s*\}\}/, text, capture: :all_but_first) |> List.flatten()

  defp load_parts(names, dir, overrides, cap),
    do: load_parts(names, dir, overrides, cap, MapSet.new())

  defp load_parts([], _, partials, _, _), do: {:ok, partials}

  defp load_parts([name | rest], dir, partials, cap, seen) do
    cond do
      not part_name?(name) ->
        error(
          :missing_partial,
          "Partial #{inspect(name)} is not a simple name; no directory traversal is allowed."
        )

      MapSet.member?(seen, name) ->
        load_parts(rest, dir, partials, cap, seen)

      MapSet.size(seen) >= 128 ->
        error(
          :partial_count,
          "More than 128 referenced partials; flatten/narrow the composition."
        )

      true ->
        read =
          case Map.fetch(partials, name) do
            {:ok, text} -> {:ok, text}
            :error -> read_template(Path.join(dir, name <> ".md"), cap)
          end

        with {:ok, text} <- read do
          load_parts(
            rest ++ references(text),
            dir,
            Map.put(partials, name, text),
            cap,
            MapSet.put(seen, name)
          )
        end
    end
  end

  def render(template, vars \\ %{}, opts \\ []) do
    partials = Keyword.get(opts, :partials, %{})
    preserve = Keyword.get(opts, :preserve, [])
    cap = Keyword.get(opts, :max_bytes, 16_000)

    if is_binary(template) and String.valid?(template) and text_map?(vars) and text_map?(partials) and
         is_list(preserve) and is_integer(cap) and cap > 0 do
      with {:ok, text} <- expand(template, vars, partials, preserve, [], cap) do
        {:ok, %{text: text, bytes: byte_size(text), approx_tokens: div(byte_size(text) + 3, 4)}}
      end
    else
      error(
        :invalid_options,
        "Give template text, string-keyed vars/partials maps and a positive max_bytes."
      )
    end
  end

  defp expand(template, vars, partials, preserve, stack, cap) do
    pieces = Regex.split(~r/(\{\{.*?\}\})/s, template, include_captures: true, trim: false)

    Enum.reduce_while(pieces, {:ok, ""}, fn piece, {:ok, acc} ->
      result =
        if String.starts_with?(piece, "{{") and String.ends_with?(piece, "}}") do
          token = piece |> String.slice(2, String.length(piece) - 4) |> String.trim()
          token(token, vars, partials, preserve, stack, cap)
        else
          if String.contains?(piece, ["{{", "}}"]),
            do: error(:syntax, "Unclosed or stray Mustache delimiter; close/remove it."),
            else: {:ok, piece}
        end

      case result do
        {:ok, value} when byte_size(acc) + byte_size(value) <= cap ->
          {:cont, {:ok, acc <> value}}

        {:ok, _} ->
          {:halt,
           error(
             :prompt_too_large,
             "Prompt exceeds #{cap} bytes; remove parts/prereads or explicitly raise max_bytes."
           )}

        error ->
          {:halt, error}
      end
    end)
  end

  defp token("!" <> _, _, _, _, _, _), do: {:ok, ""}

  defp token(">" <> name, vars, partials, preserve, stack, cap) do
    name = String.trim(name)

    cond do
      name in stack ->
        error(
          :partial_cycle,
          "Partial cycle: #{Enum.join(Enum.reverse([name | stack]), " -> ")}."
        )

      length(stack) >= 32 ->
        error(:partial_depth, "Partial nesting exceeds 32; flatten the composition.")

      not is_binary(partials[name]) ->
        error(:missing_partial, "Supply partial #{inspect(name)} as text.")

      true ->
        expand(partials[name], vars, partials, preserve, [name | stack], cap)
    end
  end

  defp token(name, vars, _, preserve, _, _) do
    cond do
      not Regex.match?(~r/^[\w.-]+$/, name) ->
        error(
          :syntax,
          "Unsupported token #{inspect(name)}; use variables, partials or comments only."
        )

      Map.has_key?(vars, name) and is_binary(vars[name]) ->
        {:ok, vars[name]}

      name in preserve ->
        {:ok, "{{#{name}}}"}

      true ->
        error(
          :missing_variable,
          "Supply variable #{inspect(name)} as text, or explicitly preserve it."
        )
    end
  end

  defp text_map?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) and String.valid?(v) end)

  defp text_map?(_), do: false

  defp error(reason, message), do: {:error, %{reason: reason, message: message}}
end
