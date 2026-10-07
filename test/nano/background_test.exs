defmodule Nano.BackgroundTest do
  use ExUnit.Case, async: true

  test "completion metadata and output" do
    assert {:ok, job} = Nano.Background.start("printf hello", notify: self())
    assert_receive {:nano_background, id, result}, 3000
    assert id == job.id
    assert result.exit_status == 0
    assert result.bytes == 5
    refute Map.has_key?(result, :text)
    assert {:ok, %{text: "hello"}} = Nano.Background.tail(id)
    assert {:ok, %{state: :finished}} = Nano.Background.status(id)
  end

  test "survives starter death and kill is group-wide" do
    parent = self()

    spawn(fn ->
      {:ok, job} = Nano.Background.start("sleep 10 & wait", notify: parent)
      send(parent, {:job, job})
    end)

    assert_receive {:job, job}, 1000
    Process.sleep(20)
    assert {:ok, %{state: :running}} = Nano.Background.status(job.id)
    assert :ok = Nano.Background.kill(job.id)
    assert_receive {:nano_background, _, %{state: :killed}}, 3000
    assert {:error, :already_finished} = Nano.Background.kill(job.id)
    assert {:error, :not_found} = Nano.Background.status("absent")
  end

  test "stable name delivers after recipient replacement and ancestry is credited" do
    name = "bg-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    parent = self()

    recipient =
      spawn(fn ->
        Registry.register(Nano.Registry, {:agent, name}, nil)
        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered
    {:ok, job} = Nano.Background.start("sleep 0.2; printf done", notify: name)
    assert {:dictionary, dict} = Process.info(job.pid, :dictionary)
    assert self() in Keyword.fetch!(dict, :"$callers")
    Process.exit(recipient, :kill)
    Process.sleep(30)

    replacement =
      spawn(fn ->
        Registry.register(Nano.Registry, {:agent, name}, nil)

        receive do
          message -> send(parent, {:forwarded, message})
        end
      end)

    assert_receive {:forwarded, {:nano_background, id, %{exit_status: 0}}}, 3000
    assert id == job.id
    refute Process.alive?(replacement)
  end

  test "waits for real completion rather than setsid parent exit" do
    {:ok, job} = Nano.Background.start("sleep 1; printf completed", notify: nil)

    assert {:ok, %{duration_ms: duration, bytes: 9, exit_status: 0}} =
             Nano.Background.await(job.id)

    assert duration >= 800
  end

  test "timeout kills descendants in the session group" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nano-bg-child-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, job} =
      Nano.Background.start("sleep 30 & echo $! > child.pid; wait",
        cwd: dir,
        timeout: 300,
        notify: nil
      )

    assert {:ok, %{state: :timed_out}} = Nano.Background.await(job.id)
    pid = File.read!(Path.join(dir, "child.pid")) |> String.trim()
    Process.sleep(30)

    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} -> :ok
      {:ok, stat} -> assert Regex.match?(~r/\) Z /, stat), "child still running: #{stat}"
    end
  end

  test "completed metadata can be redelivered and pruned without deleting output" do
    {:ok, job} = Nano.Background.start("printf retained", notify: nil)
    assert {:ok, _} = Nano.Background.await(job.id)
    assert :ok = Nano.Background.notify_again(job.id, self())
    assert_receive {:nano_background, _, %{bytes: 8}}
    assert :ok = Nano.Background.prune(job.id)
    assert {:error, :not_found} = Nano.Background.status(job.id)
    assert File.read!(job.path) == "retained"
  end

  test "dashboard-style worker kill also kills OS descendants" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nano-bg-guard-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, job} =
      Nano.Background.start("sleep 30 & echo $! > child.pid; wait", cwd: dir, notify: self())

    Process.sleep(100)
    pid = File.read!(Path.join(dir, "child.pid")) |> String.trim()
    Process.exit(job.pid, :kill)
    assert_receive {:nano_background, _, %{state: :failed}}, 3000
    Process.sleep(100)

    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} -> :ok
      {:ok, stat} -> assert Regex.match?(~r/\) Z /, stat), "child still running: #{stat}"
    end
  end

  test "invalid options


 and await deadline" do
    assert {:error, _} = Nano.Background.start("echo", timeout: -1)
    {:ok, job} = Nano.Background.start("sleep 1", notify: nil)
    assert {:error, :await_timeout} = Nano.Background.await(job.id, 1)
    assert :ok = Nano.Background.kill(job.id)
  end

  test "invalid cwd
 completes as error instead of hanging" do
    {:ok, job} = Nano.Background.start("echo x", cwd: "/missing-nano-path", notify: nil)
    assert {:ok, %{state: :failed}} = Nano.Background.await(job.id)
  end
end
