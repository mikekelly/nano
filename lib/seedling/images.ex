defmodule Seedling.Images do
  @moduledoc """
  Immutable, content-addressed PNG/JPEG attachments. `view/1` copies an image file before
  returning `{:ok, reference}`; `store/1` accepts bytes (never a filename or claimed MIME).
  References are small JSON maps, safe for transcripts, state and logs. Only `data_url/1`
  reads bytes for a provider request. Files live under `<state_dir>/images`; no garbage
  collection is performed because any old transcript may still reference them.

      {:ok, picture} = Seedling.Images.view("/tmp/screenshot.png")
      Nano.User.say("dashboard", "alice", "What is this?", [picture])

  Limits are deliberately conservative: 3,750,000 raw bytes (5 MB base64), 2,000 pixels
  per side even in a one-image request, so growing beyond 20 images cannot invalidate an
  old attachment. PNG chunks/CRCs and JPEG marker structure are checked; this is not a
  general image decoder. Animated formats, SVG, GIF and WebP are refused, not guessed.
  """

  @max_bytes 3_750_000
  @max_side 2_000
  @tokens 4_800

  @doc "Maximum accepted raw bytes, dimensions, and conservative per-image token estimate."
  def limits, do: %{bytes: @max_bytes, side: @max_side, tokens: @tokens}

  @doc "The persistent attachment directory; defaults to the node's state directory."
  def dir, do: Path.join(Application.fetch_env!(:nano, :state_dir), "images")

  @doc "Snapshot a local file, returning a reference or a readable error. Safe to return from eval."
  def view(path) when is_binary(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      store(bytes)
    else
      {:ok, _} -> {:error, "image must be a regular file of at most #{@max_bytes} bytes"}
      {:error, e} -> {:error, "cannot read image: #{:file.format_error(e)}"}
    end
  end

  def view(_), do: {:error, "image path must be a string"}

  @doc "Validate and store bytes exactly once. Concurrent identical uploads share one object."
  def store(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, metadata} <- Seedling.Images.Probe.inspect(bytes),
         :ok <- dimensions(metadata),
         id = digest(bytes),
         ref =
           Map.merge(metadata, %{
             "type" => "image_reference",
             "id" => id,
             "bytes" => byte_size(bytes)
           }),
         :ok <- persist(id, bytes) do
      {:ok, ref}
    end
  end

  def store(bytes) when is_binary(bytes),
    do: {:error, "image exceeds #{@max_bytes} raw bytes (5 MB base64)"}

  def store(_), do: {:error, "image bytes must be a binary"}

  defp dimensions(%{"width" => w, "height" => h}) when w in 1..@max_side and h in 1..@max_side,
    do: :ok

  defp dimensions(_),
    do: {:error, "image dimensions must be from 1 to #{@max_side} pixels per side"}

  defp persist(id, bytes) do
    path = Path.join(dir(), id)
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    result =
      with :ok <- File.mkdir_p(dir()),
           :ok <- File.write(tmp, bytes, [:binary, :exclusive]),
           :ok <- File.chmod(tmp, 0o444) do
        # Hard link publishes atomically without replacing an existing object.
        case File.ln(tmp, path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            with {:ok, %{type: :regular}} <- File.lstat(path),
                 {:ok, ^bytes} <- File.read(path) do
              :ok
            else
              _ -> {:error, "stored image is corrupt; refusing to replace immutable bytes"}
            end

          {:error, e} ->
            {:error, e}
        end
      end

    File.rm(tmp)

    case result do
      :ok -> :ok
      {:error, e} when is_atom(e) -> {:error, "cannot store image: #{:file.format_error(e)}"}
      other -> other
    end
  end

  @doc "Load an id or reference, verifying its hash and deriving metadata anew, not trusting caller fields."
  def fetch(%{"type" => "image_reference", "id" => id}), do: fetch(id)

  def fetch(id) when is_binary(id) do
    with true <- id =~ ~r/\A[0-9a-f]{64}\z/,
         path = Path.join(dir(), id),
         {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == id,
         {:ok, metadata} <- Seedling.Images.Probe.inspect(bytes),
         :ok <- dimensions(metadata) do
      {:ok,
       Map.merge(metadata, %{"type" => "image_reference", "id" => id, "bytes" => byte_size(bytes)}),
       bytes}
    else
      _ -> {:error, "image reference is invalid, missing or corrupt"}
    end
  end

  def fetch(_), do: {:error, "image reference must be an id or image_reference map"}

  @doc "Canonicalize a list of ids/references, rejecting missing, corrupt or excessive attachments."
  def validate_refs(refs) when is_list(refs) and length(refs) <= 100 do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case fetch(ref) do
        {:ok, canonical, _} -> {:cont, {:ok, acc ++ [canonical]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate_refs(_), do: {:error, "images must be a list of at most 100 image references"}

  @doc "Provider-only hydration. Never persist the returned data URL."
  def data_url(ref) do
    with {:ok, canonical, bytes} <- fetch(ref),
         do: {:ok, "data:" <> canonical["mime_type"] <> ";base64," <> Base.encode64(bytes)}
  end

  @doc "Find image_reference maps in an event/eval term (up to 100 refs, 10 levels, 2000 visited values)."
  def collect(term), do: walk([{term, 0}], [], 2000) |> Enum.reverse() |> Enum.uniq_by(& &1["id"])
  defp walk(_, acc, n) when n <= 0 or length(acc) >= 100, do: acc
  defp walk([], acc, _), do: acc
  defp walk([{_, depth} | rest], acc, n) when depth > 10, do: walk(rest, acc, n - 1)

  defp walk([{%{"type" => "image_reference"} = ref, _} | rest], acc, n) do
    acc = if Enum.any?(acc, &(&1["id"] == ref["id"])), do: acc, else: [ref | acc]
    walk(rest, acc, n - 1)
  end

  defp walk([{term, depth} | rest], acc, n) do
    children =
      cond do
        is_map(term) -> term |> Enum.take(n) |> Enum.map(&elem(&1, 1))
        is_tuple(term) -> for(i <- 0..(min(tuple_size(term), n) - 1)//1, do: elem(term, i))
        is_list(term) -> take_list(term, n)
        true -> []
      end

    walk(Enum.map(children, &{&1, depth + 1}) ++ rest, acc, n - 1)
  end

  defp take_list([head | tail], n) when n > 0, do: [head | take_list(tail, n - 1)]
  defp take_list(_, _), do: []

  @doc "JSON byte estimate with 9,600 extra bytes per attached image (4,800 tokens at two bytes/token)."
  def estimate_bytes(messages) do
    count =
      Enum.reduce(messages, 0, fn m, n ->
        n + if(is_map(m), do: length(Map.get(m, "images", [])), else: 0)
      end)

    byte_size(Jason.encode!(messages)) + count * @tokens * 2
  end

  @doc "Whether the saved model modalities explicitly include image input; unknown is text-only."
  def capable?(modalities), do: is_list(modalities) and "image" in modalities

  @doc "Truthful prompt addition, also for custom prompt templates and restored agents."
  def prompt(modalities) do
    if capable?(modalities) do
      "You can see attached images. To view a PNG/JPEG file on this node, return Seedling.Images.view(path) from eval. It snapshots validated immutable bytes, not merely a path."
    else
      "Your model cannot see images (image input was not listed at start). Image attachments are reported as unavailable; do not guess their contents. Seedling.Images.view(path) can store a PNG/JPEG but cannot let this model see it."
    end
  end

  @doc "Validated attachments for the saved modalities, or an explicit notice (never silently a filename)."
  def prepare(refs, modalities) do
    with {:ok, refs} <- validate_refs(refs) do
      cond do
        refs == [] ->
          {[], ""}

        capable?(modalities) ->
          {refs, ""}

        true ->
          {[],
           "\n[Images unavailable: your model cannot see images. #{length(refs)} attachment(s) were not sent; do not infer their contents.]"}
      end
    else
      {:error, reason} -> {[], "\n[Images unavailable: #{reason}. No image data was sent.]"}
    end
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
