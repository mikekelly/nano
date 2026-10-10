# Two SERIAL disposable VMs: mix run --no-start ... seed, then ... restore.
# Never use this driver with live roots. Runtime overrides are audited before app startup.
[root, mode] = System.argv()
root = Path.expand(root)

unless String.starts_with?(root, "/data/altair-flywheel/runs/pull-ef1b6e8d/runtime/"),
  do: raise("not this dispatch's private rehearsal root")

for {key, child} <- [
      state_dir: "state",
      log_dir: "logs",
      spill_dir: "spill",
      image_dir: "images",
      web_cache_dir: "web",
      safety_dir: "safety",
      test_dir: "tests"
    ] do
  path = Path.join(root, child)
  File.mkdir_p!(path)
  Application.put_env(:nano, key, path)
end

System.put_env("NANO_WEB_CACHE_DIR", Path.join(root, "web"))
System.put_env("NANO_SAFETY_DIR", Path.join(root, "safety"))
System.put_env("ERL_CRASH_DUMP", Path.join(root, "erl_crash.dump"))

IO.inspect(
  for k <- [:state_dir, :log_dir, :spill_dir, :image_dir, :web_cache_dir, :safety_dir],
      do: {k, Application.fetch_env!(:nano, k)}
)

{:ok, _} = Application.ensure_all_started(:nano)
name = "u06-disposable-restoration"

case mode do
  "seed" ->
    Nano.Settings.put(:openrouter_api_key, "test-key")
    Nano.FakeOpenRouter.start()

    model =
      Nano.FakeOpenRouter.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})

    {:ok, pid} =
      NanoAgent.start([name: name] ++ Nano.FakeOpenRouter.opts(model, max_context: 20_000))

    :sys.replace_state(
      pid,
      &Map.merge(&1, %{halted: :compaction_failed, bindings: [durable: 23]})
    )

    gif =
      <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, 44, 0::little-16, 0::little-16,
        1::little-16, 1::little-16, 0, 2, 2, 68, 1, 0, 59>>

    path = Path.join(root, "original.gif")
    File.write!(path, gif)
    {:ok, ref} = Nano.Images.import_file(path)
    send(pid, %{text: String.duplicate("é", 5000), images: [ref]})
    send(pid, :still_pending)
    for n <- 1..300, do: send(pid, {:backlog, n})
    state = :sys.get_state(pid, 60_000)
    true = length(state.pending) <= 256
    true = state.pending_backlog.count > 0
    GenServer.cast(pid, :resave)
    :sys.get_state(pid)

    expected =
      Map.take(state, [
        :id,
        :pending,
        :pending_images,
        :image_deliveries,
        :admission_evidence,
        :event_seq,
        :pending_backlog
      ])

    File.write!(Path.join(root, "expected.term"), :erlang.term_to_binary(expected))
    %{status: :durable} = Nano.StateStore.durability(name)

    IO.puts(
      "U06 forward mutation durable; pending IDs 1..302 in RAM+durable FIFO; position zero; immutable image references, no transcript pixels"
    )

  "restore" ->
    expected = root |> Path.join("expected.term") |> File.read!() |> :erlang.binary_to_term()
    pid = NanoAgent.whereis(name)
    IO.inspect(Nano.StateStore.status(), label: "restoration status")
    IO.inspect(Nano.StateStore.get(name) != nil, label: "restoration row present")

    if not is_pid(pid) do
      envelope =
        Application.fetch_env!(:nano, :state_dir)
        |> Path.join(name <> ".envelope-v1")
        |> File.read!()
        |> :erlang.binary_to_term()

      blob_bytes =
        Application.fetch_env!(:nano, :state_dir) |> Path.join(envelope.blob) |> File.read!()

      blob = :erlang.binary_to_term(blob_bytes)

      IO.inspect(
        {envelope.blob, Base.encode16(:crypto.hash(:sha256, blob_bytes), case: :lower),
         Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(blob)), case: :lower)},
        label: "binding digest diagnostic"
      )
    end

    true = is_pid(pid)
    state = :sys.get_state(pid)
    true = Enum.take(state.pending, length(expected.pending)) == expected.pending

    for key <- [:pending_images, :admission_evidence, :event_seq],
        do: true = Map.fetch!(state, key) == Map.fetch!(expected, key)

    # Restart appends its own harness notice, with an empty image attribution.
    for {text, refs} <- expected.image_deliveries,
        do: true = state.image_deliveries[text] == refs

    true = state.pending_backlog.read_index == expected.pending_backlog.read_index
    true = state.pending_backlog.count == expected.pending_backlog.count + 1
    true = state.pending_backlog.write_index == expected.pending_backlog.write_index + 1
    true = length(state.pending) == length(expected.pending)

    queue_record = fn index ->
      Application.fetch_env!(:nano, :spill_dir)
      |> Path.join(state.id)
      |> Path.join("pending-v2/#{state.pending_backlog.lifecycle_generation}-#{index}.term")
      |> File.read!()
      |> :erlang.binary_to_term([:safe])
    end

    for index <- expected.pending_backlog.read_index..expected.pending_backlog.write_index do
      envelope = queue_record.(index)
      true = envelope.agent_id == state.id
      true = envelope.lifecycle_generation == state.pending_backlog.lifecycle_generation
      true = envelope.index == index
      true = String.contains?(envelope.record.text, "<event seq=")
      true = state.pending_backlog.items[index] == expected.pending_backlog.items[index]
    end

    true = state.bindings[:durable] == 23

    true = state.halted == :compaction_failed

    for {_hash, handle} <- state.admission_evidence do
      :ok =
        Nano.ContextAdmission.validate(
          handle,
          Application.fetch_env!(:nano, :spill_dir),
          state.id
        )

      true = handle.position == 0
    end

    for ref <- state.pending_images, do: {:ok, _} = Nano.Images.read(ref)
    true = state.transcript == []

    IO.puts(
      "U06 fresh-VM roll-forward restoration passed; pending evidence/order/position/bindings/images retained; no provider request"
    )
end

Application.stop(:nano)
