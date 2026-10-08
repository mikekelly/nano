# Explicitly authorized real-provider acceptance, never invoked by mix test.
# IMAGE_SMOKE_DIR must name a task-private fresh directory containing an access-only
# chatgpt_auth.json snapshot mode0600. No refresh credential is accepted or used.
# Run: IMAGE_SMOKE_DIR=/tmp/task-private MIX_ENV=test mix run --no-start scripts/image_smoke.exs
root = System.fetch_env!("IMAGE_SMOKE_DIR") |> Path.expand()
File.mkdir_p!(root)
File.chmod!(root, 0o700)
state_dir = Path.join(root, "state")
File.mkdir_p!(state_dir)
File.chmod!(state_dir, 0o700)
source = Path.join(root, "chatgpt_auth.json")
creds = source |> File.read!() |> Jason.decode!()
true = creds["expires_at"] > System.system_time(:second) + 900
true = creds["refresh_token"] == "REFRESH_DISABLED_FOR_ISOLATED_SMOKE"
auth_file = Path.join(state_dir, "chatgpt_auth.json")
File.write!(auth_file, "")
File.chmod!(auth_file, 0o600)
File.write!(auth_file, Jason.encode!(creds))
File.rm!(source)

for {key, suffix} <- [state_dir: "state", log_dir: "logs", spill_dir: "spill"] do
  Application.put_env(:nano, key, Path.join(root, suffix))
end

{:ok, _} = Application.ensure_all_started(:nano)
:ok = Nano.Settings.put(:chatgpt_auth_url, "http://127.0.0.1:1/no-refresh")
:ok = Nano.Settings.put(:model_call_max_ms, 120_000)
:ok = Nano.Settings.put(:raw_model_log, "off")

# Only the image contains these colors. Neither filename, reference metadata nor prompt
# contains an answer, so a correct ordering demonstrates vision rather than text inference.
chunk = fn type, data ->
  <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end

row = <<0>> <> :binary.copy(<<255, 0, 0>>, 80) <> :binary.copy(<<0, 0, 255>>, 80)

png =
  <<137, 80, 78, 71, 13, 10, 26, 10>> <>
    chunk.("IHDR", <<160::32, 96::32, 8, 2, 0, 0, 0>>) <>
    chunk.("IDAT", :zlib.compress(:binary.copy(row, 96))) <>
    chunk.("IEND", "")

{:ok, ref} = Seedling.Images.store(png)
name = "image-real-#{System.unique_integer([:positive])}"

try do
  {:ok, pid} =
    NanoAgent.start(
      name: name,
      model: "openai-codex/gpt-6.1-sol",
      reasoning: "low",
      max_turns: 1,
      max_tokens: 50_000,
      max_context: 65_536,
      start_idle: true,
      system_prompt:
        "You are a narrowly scoped vision acceptance agent. Inspect the attached picture, not its metadata. Reply without tools using exactly one JSON object with lowercase English color names for keys left and right."
    )

  info = NanoAgent.info(name)
  true = Seedling.Images.capable?(info.input_modalities)
  Nano.Log.subscribe(info.id)

  send(pid, %{
    message: "What color is the left panel and what color is the right panel?",
    image: ref
  })

  deadline = System.monotonic_time(:millisecond) + 150_000

  wait = fn wait ->
    entries = Nano.Log.read(info.id)

    cond do
      response = Enum.find(entries, &(&1["type"] == "model_response")) ->
        {:ok, response}

      error = Enum.find(entries, &(&1["type"] == "model_error")) ->
        {:error, Map.take(error, ~w(status class retry body))}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :deadline}

      true ->
        Process.sleep(100)
        wait.(wait)
    end
  end

  case wait.(wait) do
    {:ok, response} ->
      answer = response["text"] || ""

      result =
        case Jason.decode(String.trim(answer)) do
          {:ok, %{"left" => "red", "right" => "blue"}} -> :passed
          _ -> :failed
        end

      saved = Nano.StateStore.get(name)
      false = :erlang.term_to_binary(saved) =~ "data:image"

      summary = %{
        result: result,
        model: info.model,
        input_modalities: info.input_modalities,
        answer: answer,
        prompt_tokens: response["prompt_tokens"],
        completion_tokens: response["completion_tokens"],
        image_id: ref["id"],
        bytes: ref["bytes"],
        width: ref["width"],
        height: ref["height"]
      }

      File.write!(Path.join(root, "result.json"), Jason.encode!(summary, pretty: true))
      IO.puts(Jason.encode!(summary))
      if result != :passed, do: raise("vision acceptance answer did not match visible colors")

    {:error, reason} ->
      raise("real vision call failed: #{inspect(reason)}")
  end

  Nano.Ops.stop_agent(name)
after
  # Credentials are removed even when the provider or assertions fail.
  File.rm(auth_file)
  File.rm(source)
end
