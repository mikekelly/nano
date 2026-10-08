defmodule Seedling.Delegation.Supervisor do
  @moduledoc "Boot child: place after Nano.StateStore. Restores durable named-parent monitor records."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def ensure_started do
    if Process.whereis(__MODULE__) do
      :ok
    else
      case start_link([]) do
        {:ok, pid} ->
          Process.unlink(pid)
          :ok

        {:error, {:already_started, _}} ->
          :ok

        error ->
          error
      end
    end
  end

  def init(opts) do
    restore? =
      Keyword.get(opts, :restore, true) or :persistent_term.get({__MODULE__, :boot_ready}, false)

    Supervisor.init(
      [
        {DynamicSupervisor, name: Seedling.Delegation.Workers, strategy: :one_for_one},
        %{
          id: :restore,
          start: {Task, :start_link, [fn -> if restore?, do: restore() end]},
          restart: :temporary
        }
      ],
      strategy: :one_for_all
    )
  end

  def directory, do: Path.join(Application.fetch_env!(:nano, :state_dir), "delegation")
  def file(name), do: Path.join(directory(), Base.url_encode64(name, padding: false) <> ".term")

  def save(s) do
    File.mkdir_p!(directory())
    path = file(s.name)

    with :ok <-
           File.write(
             path <> ".tmp",
             :erlang.term_to_binary(Map.take(s, [:name, :parent, :interval, :pending, :done]))
           ),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end

  def restore do
    :persistent_term.put({__MODULE__, :boot_ready}, true)

    for path <- Path.wildcard(Path.join(directory(), "*.term")) do
      with {:ok, raw} <- File.read(path) do
        try do
          s = :erlang.binary_to_term(raw, [:safe])

          DynamicSupervisor.start_child(
            Seedling.Delegation.Workers,
            {Seedling.Delegation.Monitor, s}
          )
        rescue
          _ -> :skip_corrupt_record
        end
      end
    end
  end
end
