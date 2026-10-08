defmodule Nano.Images do
  @moduledoc "Immutable image attachments. view(path, agent) sends a PNG/JPEG file; send(agent, text, bytes) accepts upload bytes. State/logs store refs only."
  def view(path, agent) do
    with {:ok, bytes} <- File.read(path), do: send(agent, "Image from #{path}", bytes)
  end

  def send(agent, text, bytes) when is_binary(text) do
    pid = if is_pid(agent), do: agent, else: NanoAgent.whereis(agent)

    with true <- is_pid(pid) and Process.alive?(pid), {:ok, ref} <- store(bytes) do
      Kernel.send(pid, {:nano_image, text, ref})
      {:ok, ref}
    else
      false -> {:error, "agent is not running"}
      error -> error
    end
  end

  def store(bytes) when is_binary(bytes) and byte_size(bytes) <= 3_500_000 do
    with {:ok, mime, w, h} <- dimensions(bytes),
         true <- w in 1..2000 and h in 1..2000,
         :ok <- File.mkdir_p(dir()) do
      id = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      ref = %{"type" => "nano_image", "id" => id, "mime" => mime, "width" => w, "height" => h}

      case File.write(Path.join(dir(), id), bytes, [:exclusive]) do
        :ok -> {:ok, ref}
        {:error, :eexist} -> {:ok, ref}
        error -> error
      end
    else
      false -> {:error, "image dimensions must be 1..2000 pixels per side"}
      error -> error
    end
  end

  def store(_), do: {:error, "image must be PNG/JPEG bytes, at most 3.5MB"}

  def fetch(id) when is_binary(id) do
    if id =~ ~r/\A[0-9a-f]{64}\z/ do
      with {:ok, bytes} <- File.read(Path.join(dir(), id)),
           ^id <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
           {:ok, mime, _, _} <- dimensions(bytes),
           do: {:ok, bytes, mime}
    else
      {:error, :invalid_id}
    end
  end

  def fetch(_), do: {:error, :invalid_id}

  defp dir,
    do:
      Application.get_env(
        :nano,
        :image_dir,
        Path.join(Application.fetch_env!(:nano, :log_dir), "images")
      )

  def dimensions(
        <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, header::binary-size(5),
          _crc::32, rest::binary>>
      ) do
    if png_chunks?(rest, false) and byte_size(header) == 5,
      do: {:ok, "image/png", w, h},
      else: {:error, "truncated or invalid PNG chunks"}
  end

  def dimensions(<<255, 216, rest::binary>>) do
    if String.ends_with?(rest, <<255, 217>>), do: jpeg(rest), else: {:error, "truncated JPEG"}
  end

  def dimensions(_), do: {:error, "unsupported or invalid image bytes (PNG/JPEG only)"}

  defp png_chunks?(<<0::32, "IEND", _crc::32>>, seen), do: seen

  defp png_chunks?(<<size::32, kind::binary-size(4), rest::binary>>, seen) do
    case rest do
      <<_chunk::binary-size(^size), _crc::32, tail::binary>> ->
        png_chunks?(tail, seen or kind == "IDAT")

      _ ->
        false
    end
  end

  defp png_chunks?(_, _), do: false

  defp jpeg(<<255, marker, length::16, data::binary>>) when length >= 2 do
    size = length - 2

    case data do
      <<segment::binary-size(^size), rest::binary>> ->
        if marker in [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207] do
          case segment do
            <<_, h::16, w::16, _::binary>> -> {:ok, "image/jpeg", w, h}
            _ -> {:error, "invalid JPEG frame"}
          end
        else
          jpeg(rest)
        end

      _ ->
        {:error, "truncated JPEG"}
    end
  end

  defp jpeg(<<255, 255, rest::binary>>), do: jpeg(<<255, rest::binary>>)
  defp jpeg(_), do: {:error, "invalid JPEG header"}

  def expand(messages) do
    Enum.map(messages, fn
      %{"content" => parts} = m when is_list(parts) ->
        %{m | "content" => Enum.map(parts, &expand_part/1)}

      m ->
        m
    end)
  end

  defp expand_part(%{"type" => "nano_image", "id" => id}) do
    case fetch(id) do
      {:ok, bytes, mime} ->
        %{
          "type" => "image_url",
          "image_url" => %{"url" => "data:#{mime};base64," <> Base.encode64(bytes)}
        }

      _ ->
        %{"type" => "text", "text" => "Image #{id} is unavailable; do not guess its contents."}
    end
  end

  defp expand_part(part), do: part
end
