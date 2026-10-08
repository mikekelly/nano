defmodule Images do
  @moduledoc """
  Immutable, content-addressed image attachments. `Images.view(path)` in an eval shows a
  local image to the agent (even when it is not the eval's last expression). `ingest/1`
  copies a file; `ingest_bytes/1` accepts uploaded bytes. Both return `{:ok, ref}` or
  `{:error, message}`. Send `Images.message("What is this?", [ref])` with
  `NanoAgent.notify/2`. References, never base64, belong in saved state and logs.

  PNG, JPEG, static GIF and static WebP are detected from bytes. Maximum encoded size is
  5,000,000 base64 bytes (3,750,000 raw); every side must be 1..2000 pixels, so images
  stay valid when a conversation grows beyond 20 images. Animated images are refused.
  Header/container validation is not a full pixel decoder. Invalid or unavailable files
  produce explicit notices, not guesses. Up to 100 image occurrences per active context
  are admitted by the harness; compaction can free space.

  Files live under `Application.get_env(:nano, :images_dir, "/data/images")`, hash-named
  and published atomically without replacement. `read/1` verifies content hash and type
  on every use. There is no automatic garbage collection: transcripts can reference these
  files indefinitely. Back up this directory with agent state. Root operators can change
  files; corruption is detected, never silently sent as another image.
  """

  @max_bytes 3_750_000
  @token_cost 4_800
  @max_images 100

  def max_bytes, do: @max_bytes
  def token_cost, do: @token_cost
  def max_images, do: @max_images
  def directory, do: Application.get_env(:nano, :images_dir, "/data/images")

  @doc "Copy a local regular file into the immutable store, validating before publication."
  def ingest(path) when is_binary(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, data} <- File.read(path) do
      ingest_bytes(data)
    else
      {:ok, %{size: size}} when size > @max_bytes ->
        {:error, "image exceeds #{@max_bytes} raw bytes"}

      _ ->
        {:error, "image file is not a readable regular file"}
    end
  end

  def ingest(_), do: {:error, "image path must be a string"}

  @doc "Validate uploaded bytes and return a small, JSON-safe attachment reference."
  def ingest_bytes(data) when is_binary(data) and byte_size(data) <= @max_bytes do
    with {:ok, mime, width, height} <- Images.Format.identify(data),
         :ok <- dimensions(width, height),
         ref = reference(data, mime, width, height),
         :ok <- publish(ref["id"], data) do
      {:ok, ref}
    end
  end

  def ingest_bytes(data) when is_binary(data),
    do: {:error, "image exceeds #{@max_bytes} raw bytes (5 MB base64)"}

  def ingest_bytes(_), do: {:error, "image bytes must be a binary"}

  @doc "Show a file in the current eval; data does not enter the inspected result or bindings."
  def view(path) do
    with {:ok, ref} <- ingest(path) do
      Process.put({__MODULE__, :viewed}, Process.get({__MODULE__, :viewed}, []) ++ [ref])
      {:ok, ref}
    end
  end

  @doc false
  def take_viewed, do: Process.delete({__MODULE__, :viewed}) || []

  @doc "A mailbox event with text and attachments, accepted by NanoAgent.notify/2."
  def message(text, refs) when is_binary(text) and is_list(refs), do: %{text: text, images: refs}

  @doc "Read by reference or SHA-256 ID, verifying bytes, type and dimensions. Never follows arbitrary paths."
  def read(ref_or_id) do
    id = if is_map(ref_or_id), do: ref_or_id["id"], else: ref_or_id

    with true <- valid_id?(id),
         {:ok, %{type: :regular, size: size}} when size <= @max_bytes <-
           File.lstat(Path.join(directory(), id)),
         {:ok, data} <- File.read(Path.join(directory(), id)),
         true <- hash(data) == id,
         {:ok, mime, w, h} <- Images.Format.identify(data),
         :ok <- dimensions(w, h) do
      {:ok, data, mime}
    else
      _ -> {:error, "image attachment unavailable, invalid or corrupt"}
    end
  end

  @doc "Canonical metadata from stored bytes; never trusts client-supplied MIME or dimensions."
  def resolve(ref_or_id) do
    with {:ok, data, mime} <- read(ref_or_id),
         {:ok, ^mime, w, h} <- Images.Format.identify(data) do
      {:ok, reference(data, mime, w, h)}
    end
  end

  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id)

  @doc "Image references within a term (including tuples returned by eval). Does not parse inspected text."
  def references(%{"type" => "image_ref"} = ref), do: [ref]
  def references(term) when is_map(term), do: term |> Map.values() |> Enum.flat_map(&references/1)
  def references(term) when is_list(term), do: Enum.flat_map(term, &references/1)
  def references(term) when is_tuple(term), do: term |> Tuple.to_list() |> references()
  def references(_), do: []

  @doc "Validate references before admission; returns canonical refs and explicit rejection notices."
  def admit(refs, available \\ @max_images) do
    Enum.reduce(refs, {[], []}, fn ref, {accepted, notices} ->
      if length(accepted) >= available do
        {accepted,
         notices ++ ["Image not attached: active context image limit (#{@max_images}) reached."]}
      else
        case resolve(ref) do
          {:ok, canonical} -> {accepted ++ [canonical], notices}
          {:error, why} -> {accepted, notices ++ ["Image not attached: #{why}."]}
        end
      end
    end)
  end

  @doc "Whether the saved catalog modalities explicitly include images; unknown means no."
  def capable?(modalities), do: is_list(modalities) and "image" in modalities

  @doc "Lean capability statement, appended even to custom system prompt templates."
  def prompt(modalities) do
    if capable?(modalities) do
      "Images: you can see attached images. Use Images.view(path) in eval to view a local image; see Code.fetch_docs(Images). A filename alone is not an image."
    else
      "Images: this model cannot see images (or its image support is unverified). Attachments are identified but not sent as pixels; do not guess their contents. Images.view(path) cannot change this capability."
    end
  end

  @doc "Canonical chat content; incapable models always receive an explicit per-delivery notice."
  def content(text, [], _modalities), do: text

  def content(text, refs, modalities) do
    if capable?(modalities) do
      [%{"type" => "text", "text" => text} | refs]
    else
      text <>
        "\n[Images not visible: this model cannot see images (or image support is unverified). " <>
        "Do not infer their contents. Attachment IDs: " <>
        Enum.map_join(refs, ", ", & &1["id"]) <> "]"
    end
  end

  @doc "Request size in equivalent bytes: each image costs 4,800 tokens, not its base64 length."
  def estimated_bytes(term) do
    byte_size(Jason.encode!(without_refs(term))) + length(references(term)) * @token_cost * 2
  end

  defp without_refs(%{"type" => "image_ref"}), do: nil
  defp without_refs(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, without_refs(v)} end)
  defp without_refs(list) when is_list(list), do: Enum.map(list, &without_refs/1)
  defp without_refs(other), do: other

  defp dimensions(w, h) when w in 1..2000 and h in 1..2000, do: :ok

  defp dimensions(_, _),
    do: {:error, "image dimensions must be 1..2000 pixels per side (safe for long conversations)"}

  defp hash(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp reference(data, mime, w, h),
    do: %{
      "type" => "image_ref",
      "id" => hash(data),
      "mime" => mime,
      "width" => w,
      "height" => h,
      "bytes" => byte_size(data)
    }

  defp publish(id, data) do
    root = directory()

    temp =
      Path.join(
        root,
        ".upload-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    path = Path.join(root, id)

    try do
      with :ok <- File.mkdir_p(root),
           :ok <- File.write(temp, data, [:binary, :exclusive]),
           :ok <- File.chmod(temp, 0o444) do
        case File.ln(temp, path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            case read(id) do
              {:ok, ^data, _} -> :ok
              _ -> {:error, "existing image attachment is corrupt; refusing replacement"}
            end

          {:error, reason} ->
            {:error, "cannot publish image: #{inspect(reason)}"}
        end
      else
        {:error, reason} -> {:error, "cannot store image: #{inspect(reason)}"}
      end
    after
      File.rm(temp)
    end
  end
end
