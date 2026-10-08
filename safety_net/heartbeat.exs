# Loaded from the installed safety runtime, not from the mutable app checkout.
# Blocking supervisor/endpoint calls prevent a live-but-wedged service looking healthy.
spawn(fn ->
  session = System.fetch_env!("SAFETY_NET_SESSION")
  token = System.fetch_env!("SAFETY_NET_TOKEN")

  announce = fn ->
    announced = Process.get(:safety_announced, MapSet.new())
    names = Enum.reject(NanoAgent.list(), &MapSet.member?(announced, &1))

    if names != [] do
      path = Path.join(System.fetch_env!("SAFETY_NET_HOME"), "reports.jsonl")

      # Metadata only, bounded even after a long deployment. Newly revived or created
      # agents are announced on a later tick if revival was not complete at readiness.
      with {:ok, io} <- File.open(path, [:read, :binary]) do
        {:ok, size} = :file.position(io, :eof)
        :file.position(io, max(0, size - 8192))
        reports = IO.binread(io, 8192)
        File.close(io)
        summary = reports |> to_string() |> String.split("\n", trim: true) |> Enum.take(-5)
        for name <- names, do: NanoAgent.notify(name, {:safety_net, summary})
        Process.put(:safety_announced, MapSet.union(announced, MapSet.new(names)))
      end
    end
  end

  tick = fn ->
    try do
      if Process.whereis(Nano.Supervisor) && Process.whereis(NanoWeb.Endpoint) do
        Supervisor.which_children(Nano.Supervisor)
        :sys.get_state(NanoWeb.Endpoint, 5_000)
        tmp = Path.join(session, "heartbeat.tmp")
        File.write!(tmp, token)
        File.rename!(tmp, Path.join(session, "heartbeat"))
        if Code.ensure_loaded?(NanoAgent), do: announce.()
      end
    catch
      _, _ -> :ok
    end
  end

  Stream.repeatedly(fn ->
    tick.()
    Process.sleep(2_000)
  end)
  |> Stream.run()
end)
