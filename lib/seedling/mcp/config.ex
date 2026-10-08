defmodule Seedling.MCP.Config do
  @moduledoc false
  import Seedling.MCP, only: [error: 2]
  def default_path, do: "/app/priv/seedling/mcp.json"

  def names(path) do
    with {:ok, config} <- load(path), do: {:ok, config |> Map.keys() |> Enum.sort()}
  end

  def load(path) do
    with {:ok, result} <- Seedling.Files.read(path, max_bytes: 1_000_000, limit: 10_000),
         false <- result.truncated,
         {:ok, %{"servers" => servers}} when is_map(servers) <- Jason.decode(result.text) do
      {:ok, servers}
    else
      _ ->
        error(
          :invalid_config,
          "Read valid JSON {\"servers\": {...}} from #{path}; cap 1 MB/10000 lines."
        )
    end
  end

  def get(path, name) do
    with {:ok, servers} <- load(path),
         {:ok, raw} <- Map.fetch(servers, name),
         {:ok, config} <- expand(raw),
         :ok <- validate(config) do
      {:ok, config}
    else
      :error -> error(:unknown_server, "No server #{inspect(name)} in #{path}; use servers/1.")
      other -> other
    end
  end

  defp expand(value) do
    {:ok, expand_value(value)}
  rescue
    e -> error(:missing_env, Exception.message(e))
  end

  defp expand_value(v) when is_binary(v) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, v, fn _, key ->
      System.get_env(key) || raise "Set environment variable #{key} before connecting."
    end)
  end

  defp expand_value(v) when is_list(v), do: Enum.map(v, &expand_value/1)
  defp expand_value(v) when is_map(v), do: Map.new(v, fn {k, val} -> {k, expand_value(val)} end)
  defp expand_value(v), do: v

  defp validate(c) when is_map(c) do
    cap = c["max_message_bytes"] || 8_000_000

    valid =
      case c["transport"] do
        "stdio" ->
          is_binary(c["command"]) and c["command"] != "" and
            is_list(c["args"] || []) and Enum.all?(c["args"] || [], &is_binary/1) and
            is_map(c["env"] || %{}) and
            Enum.all?(c["env"] || %{}, fn {k, v} -> is_binary(k) and is_binary(v) end) and
            (is_nil(c["cwd"]) or (is_binary(c["cwd"]) and File.dir?(c["cwd"])))

        "http" ->
          is_binary(c["url"]) and URI.parse(c["url"]).scheme in ["http", "https"] and
            is_binary(URI.parse(c["url"]).host) and is_map(c["headers"] || %{}) and
            Enum.all?(c["headers"] || %{}, fn {k, v} ->
              is_binary(k) and is_binary(v) and not String.contains?(k <> v, ["\r", "\n"])
            end)

        _ ->
          false
      end

    if valid and is_integer(cap) and cap > 0,
      do: :ok,
      else:
        error(
          :invalid_config,
          "Server needs transport stdio + command/args/env/cwd, or http + url/headers; max_message_bytes positive."
        )
  end

  defp validate(_), do: error(:invalid_config, "Server config must be an object.")
end

defmodule Seedling.MCP.Bounds do
  @moduledoc false
  import Seedling.MCP, only: [error: 2]

  def valid?(opts),
    do:
      Enum.all?(
        [Keyword.get(opts, :max_bytes, 12_000), Keyword.get(opts, :max_items, 50)],
        &(is_integer(&1) and &1 > 0)
      )

  def wrap(data, dir, opts \\ []) do
    text = Jason.encode!(data)
    cap = Keyword.get(opts, :max_bytes, 12_000)
    items = Keyword.get(opts, :max_items, 50)

    item_cut =
      is_map(data) and
        Enum.any?(
          ["tools", "resources", "resourceTemplates", "prompts", "subscriptions"],
          fn key ->
            is_list(data[key]) and length(data[key]) > items
          end
        )

    cut = byte_size(text) > cap or item_cut

    if cut do
      path =
        Path.join(
          dir,
          "result-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(4))}.json"
        )

      {path, spill_error} =
        case Seedling.Files.write(path, text) do
          {:ok, _} -> {path, nil}
          {:error, e} -> {nil, e}
        end

      preview_data =
        if item_cut,
          do:
            Map.new(data, fn {k, v} ->
              {k,
               if(
                 k in ["tools", "resources", "resourceTemplates", "prompts", "subscriptions"] and
                   is_list(v),
                 do: Enum.take(v, items),
                 else: v
               )}
            end),
          else: data

      preview = Jason.encode!(preview_data)
      shown = prefix(preview, cap)
      # Paging always indexes the complete JSON, not the shortened item preview.
      offset = byte_size(prefix(text, cap))

      %{
        data: if(byte_size(preview) <= cap, do: preview_data, else: nil),
        text: shown,
        truncated: true,
        output_path: path,
        next_offset: if(path && offset < byte_size(text), do: offset, else: nil),
        spill_error: spill_error,
        bytes: byte_size(text),
        next_cursor: cursor(data),
        notice:
          if(path,
            do:
              "Result limited to #{cap} bytes/#{items} items. Complete JSON: #{path}; page(path, offset: 0) or next_offset; next_cursor continues server discovery.",
            else:
              "Result cut; spill failed: #{spill_error.message}. Fix state_dir permissions or increase max_bytes/max_items; no complete result saved."
          )
      }
    else
      %{
        data: data,
        text: text,
        truncated: false,
        output_path: nil,
        next_offset: nil,
        bytes: byte_size(text),
        next_cursor: cursor(data),
        notice: nil
      }
    end
  end

  defp cursor(data) when is_map(data), do: data["nextCursor"]
  defp cursor(_), do: nil

  def prefix(text, cap) do
    part = binary_part(text, 0, min(cap, byte_size(text)))
    trim_invalid(part)
  end

  defp trim_invalid(""), do: ""

  defp trim_invalid(part) do
    if String.valid?(part),
      do: part,
      else: trim_invalid(binary_part(part, 0, byte_size(part) - 1))
  end

  def page(path, opts) do
    offset = Keyword.get(opts, :offset, 0)
    cap = Keyword.get(opts, :max_bytes, 12_000)

    if is_integer(offset) and offset >= 0 and is_integer(cap) and cap >= 4 do
      with {:ok, io} <- File.open(path, [:read, :binary]) do
        result =
          with {:ok, size} <- :file.position(io, :eof),
               true <- offset <= size,
               {:ok, _} <- :file.position(io, offset) do
            raw =
              case IO.binread(io, cap) do
                :eof -> ""
                value -> value
              end

            if is_binary(raw) and String.valid?(raw |> prefix(cap)) do
              text = prefix(raw, cap)

              if raw != "" and text == "",
                do: error(:invalid_offset, "offset must be at a UTF-8 character boundary."),
                else:
                  {:ok,
                   %{
                     text: text,
                     offset: offset,
                     next_offset:
                       if(offset + byte_size(text) < size,
                         do: offset + byte_size(text),
                         else: nil
                       ),
                     bytes: size,
                     truncated: offset + byte_size(text) < size
                   }}
            else
              error(:invalid_offset, "offset must be at a UTF-8 character boundary.")
            end
          else
            _ -> error(:invalid_offset, "offset is past end of result file or cannot seek.")
          end

        File.close(io)
        result
      else
        {:error, r} -> error(r, "Cannot read result file #{path}: #{inspect(r)}")
      end
    else
      error(:invalid_options, "Use offset >= 0 and max_bytes >= 4.")
    end
  end
end
