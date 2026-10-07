# Run with MIX_ENV=test mix run --no-start test/vision_smoke.exs /path/to/auth.json
# Only the isolated child VM reads credentials. No credential contents are printed.
[source] = System.argv()

root =
  Path.join(System.tmp_dir!(), "vega-images-real-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

File.mkdir_p!(root)
Application.put_env(:nano, :state_dir, root)
Application.put_env(:nano, :log_dir, Path.join(root, "logs"))
Application.put_env(:nano, :spill_dir, Path.join(root, "spill"))
File.cp!(source, Path.join(root, "chatgpt_auth.json"))
File.chmod!(Path.join(root, "chatgpt_auth.json"), 0o600)

try do
  Application.ensure_all_started(:nano)
  Nano.Settings.put(:openrouter_api_key, nil)
  w = 192
  h = 128
  glyphs = ["10010100101111100010000100001000010", "11111000100010001000010000100001000"]

  ink =
    for {glyph, index} <- Enum.with_index(glyphs),
        {pixel, pos} <- glyph |> String.graphemes() |> Enum.with_index(),
        pixel == "1",
        dx <- 0..3,
        dy <- 0..3,
        into: MapSet.new(),
        do: {70 + index * 36 + rem(pos, 5) * 4 + dx, 45 + div(pos, 5) * 4 + dy}

  rows =
    for y <- 0..(h - 1), into: <<>> do
      row =
        for x <- 0..(w - 1), into: <<>> do
          cond do
            MapSet.member?(ink, {x, y}) -> <<0, 0, 0>>
            x in 48..143 and y in 32..95 -> <<255, 255, 0>>
            x < 96 -> <<255, 0, 0>>
            true -> <<0, 0, 255>>
          end
        end

      <<0, row::binary>>
    end

  chunk = fn kind, data ->
    <<byte_size(data)::32, kind::binary, data::binary, :erlang.crc32(kind <> data)::32>>
  end

  bytes =
    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk.("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk.("IDAT", :zlib.compress(rows)) <> chunk.("IEND", <<>>)

  {:ok, ref} = Vega.Images.import_bytes(bytes)
  catalog = Nano.ChatGPT.models()
  entry = Enum.find(catalog, &(&1.id == "gpt-6.1-sol"))
  IO.inspect(Map.take(entry || %{}, [:id, :input_modalities]), label: "catalog")

  messages = [
    %{"role" => "system", "content" => "Describe only what you see in the image. Be concise."},
    %{
      "role" => "user",
      "content" =>
        Vega.Images.content(
          "What colors are on the left and right, and what number is printed in the central panel?",
          [ref]
        )
    }
  ]

  case Nano.Model.chat("openai-codex/gpt-6.1-sol", messages, [], "low", nil) do
    {:ok, r} ->
      IO.inspect(%{text: r.message["content"], usage: r.usage}, label: "vision_result")

    {:error, e} ->
      IO.inspect(Map.take(e, [:status, :limit]), label: "vision_error")
      raise "vision request failed (details intentionally omitted)"
  end

  IO.inspect(
    %{
      persisted_ref_bytes: byte_size(Jason.encode!(ref)),
      raw_bytes: byte_size(bytes),
      estimated_image_tokens: div(Vega.Images.estimated_bytes(ref), 2)
    },
    label: "image_accounting"
  )
after
  Application.stop(:nano)
  File.rm_rf!(root)
end
