# Opt-in fixture investigation. Run with --no-start so the audit precedes app effects.
false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :nano end)
ExUnit.start(autorun: false, seed: 1515)
root = System.fetch_env!("U15_PRIVATE_ROOT") |> Path.expand()
tmp = System.fetch_env!("U15_TMP_ROOT") |> Path.expand()

inside = fn path, parent ->
  is_binary(path) and String.starts_with?(Path.expand(path), parent <> "/")
end

paths =
  Map.new(
    [:test_dir, :state_dir, :log_dir, :spill_dir, :image_dir, :web_cache_dir, :safety_dir],
    fn key -> {key, Application.fetch_env!(:nano, key)} end
  )

for {_, path} <- paths, do: true = inside.(path, tmp)

for key <- ["MIX_BUILD_ROOT", "MIX_BUILD_PATH", "MIX_DEPS_PATH", "HOME", "MIX_HOME", "HEX_HOME"],
    do: true = inside.(System.fetch_env!(key), root)

true = inside.(System.fetch_env!("TMPDIR"), tmp)
true = inside.(System.fetch_env!("NANO_WEB_CACHE_DIR"), tmp)
true = inside.(System.fetch_env!("NANO_SAFETY_DIR"), tmp)
true = inside.(System.fetch_env!("ERL_CRASH_DUMP"), tmp)
false = Application.fetch_env!(:nano, NanoWeb.Endpoint)[:server]
IO.puts("U15_PATH_AUDIT " <> Jason.encode!(paths))
File.mkdir_p!(root <> "/evidence")
File.write!(root <> "/evidence/path-audit.json", Jason.encode!(paths, pretty: true))
{:ok, _} = Application.ensure_all_started(:nano)

defmodule U15Investigation do
  use ExUnit.Case, async: false
  alias Nano.Search

  defp opts(dir, transport),
    do: [
      dir: dir,
      transport: transport,
      owner: "u15-absent-fixture",
      timeout: 2000,
      delivery_timeout: 10,
      poll_interval: 10,
      research_timeout: 1000,
      retries: 0
    ]

  defp receive_created do
    receive do
      {:created, task} -> task
    after
      2500 -> flunk("create barrier not reached")
    end
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2500
  end

  defp record(name, data) do
    File.write!(
      System.fetch_env!("U15_PRIVATE_ROOT") <> "/evidence/" <> name <> ".json",
      Jason.encode!(data, pretty: true)
    )

    IO.puts("U15_SCENARIO " <> name <> " " <> Jason.encode!(data))
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "u15-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "remote acceptance before response/local ID: crash cannot resume or cancel", %{dir: dir} do
    caller = self()

    transport = fn :post, "/agent/runs", _ ->
      send(caller, {:created, self()})

      receive do
        :return -> {:ok, 200, %{}, %{"id" => "orphan", "status" => "running"}}
      end
    end

    {:ok, handle} = Search.research("fixture", opts(dir, transport))
    receive_created()
    stop(handle.pid)
    assert {:ok, %{status: :interrupted, remote_id: nil}} = Search.status(handle)
    assert {:error, %{kind: :not_resumable}} = Search.resume(handle, opts(dir, transport))
    assert {:ok, %{remote_id: nil}} = Search.cancel(handle, opts(dir, transport))
    refute_receive {:created, _}, 50

    record("crash-before-id", %{
      remote_acceptances: 1,
      remote_cancel_requests: 0,
      local_id: nil,
      outcome: "orphan window confirmed; cancel returns status without cancellation"
    })
  end

  test "create response success then atomic status rename fails: ID is lost", %{dir: dir} do
    caller = self()

    transport = fn :post, "/agent/runs", _ ->
      send(caller, {:created, self()})

      receive do
        :return -> {:ok, 200, %{}, %{"id" => "orphan", "status" => "running"}}
      end
    end

    {:ok, handle} = Search.research("fixture", opts(dir, transport))
    task = receive_created()
    status = File.read!(handle.dir <> "/status.term")
    File.rm!(handle.dir <> "/status.term")
    File.mkdir!(handle.dir <> "/status.term")
    ref = Process.monitor(handle.pid)
    send(task, :return)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2500
    assert {:error, :eisdir} = Search.status(handle)
    # Reset only the deliberate fixture obstruction to inspect preserved old bytes.
    File.rmdir!(handle.dir <> "/status.term")
    File.write!(handle.dir <> "/status.term", status)
    assert {:ok, %{remote_id: nil, status: :interrupted}} = Search.status(handle)
    assert {:error, %{kind: :not_resumable}} = Search.resume(handle, opts(dir, transport))
    assert {:ok, %{remote_id: nil}} = Search.cancel(handle, opts(dir, transport))

    record("persistence-after-create", %{
      remote_acceptances: 1,
      remote_cancel_requests: 0,
      outcome:
        "success response followed by rename failure loses remote ID; preserved starting checkpoint cannot reconcile"
    })
  end

  test "durable ID after crash resumes by GET and confirmed cancel stops poller", %{dir: dir} do
    caller = self()

    transport = fn method, path, _ ->
      send(caller, {:request, method, path})

      case {method, path} do
        {:post, "/agent/runs"} ->
          {:ok, 200, %{}, %{"id" => "known/id", "status" => "running"}}

        {:get, "/agent/runs/known%2Fid"} ->
          send(caller, {:created, self()})

          receive do
            :return -> {:ok, 200, %{}, %{"id" => "known/id", "status" => "running"}}
          end

        {:post, "/agent/runs/known%2Fid/cancel"} ->
          {:ok, 200, %{}, %{"id" => "known/id", "status" => "cancelled"}}
      end
    end

    {:ok, handle} = Search.research("fixture", opts(dir, transport))
    receive_created()
    stop(handle.pid)
    assert {:ok, %{status: :interrupted, remote_id: "known/id"}} = Search.status(handle)
    {:ok, resumed} = Search.resume(handle, opts(dir, transport))
    receive_created()
    assert {:ok, _} = Search.cancel(resumed, opts(dir, transport))
    refute Process.alive?(resumed.pid)
    assert {:ok, %{status: "cancelled", remote_id: "known/id"}} = Search.status(handle)

    requests =
      Stream.repeatedly(fn ->
        receive do
          {:request, method, path} -> {method, path}
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert Enum.count(requests, &(&1 == {:post, "/agent/runs"})) == 1
    assert Enum.count(requests, &(&1 == {:get, "/agent/runs/known%2Fid"})) == 2
    assert Enum.count(requests, &(&1 == {:post, "/agent/runs/known%2Fid/cancel"})) == 1

    record("durable-id-recovery", %{
      create_requests: 1,
      get_requests: 2,
      cancel_requests: 1,
      outcome:
        "resume avoids recreation; fixture-confirmed terminal cancel persists and stops local poller",
      billing_verified: false
    })
  end
end

result = ExUnit.run()
if result.failures > 0, do: System.halt(1)
