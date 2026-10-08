defmodule MCPStdioTest do
  use ExUnit.Case, async: true

  defp start_python(code, extra \\ %{}) do
    MCP.Stdio.start(
      Map.merge(
        %{"command" => "python3", "args" => ["-u", "-c", code], "cwd" => System.tmp_dir!()},
        extra
      ),
      self()
    )
  end

  test "split frames reassemble and multiple frames are delivered independently" do
    code =
      "import sys,time; sys.stdout.write('{\"jsonrpc\":\"2.0\",'); sys.stdout.flush(); time.sleep(.05); print('\"method\":\"a\"}'); print('{\"jsonrpc\":\"2.0\",\"method\":\"b\"}'); time.sleep(2)"

    assert {:ok, pid} = start_python(code)
    assert_receive {:mcp_transport, ^pid, {:message, %{"method" => "a"}}}, 1000
    assert_receive {:mcp_transport, ^pid, {:message, %{"method" => "b"}}}, 1000
    MCP.Stdio.close(pid)
  end

  test "oversized unterminated frames and invalid JSON fail, not unbounded buffers" do
    assert {:ok, pid} =
             start_python(
               "import sys,time; sys.stdout.write('x'*2048); sys.stdout.flush(); time.sleep(1)",
               %{"max_message_bytes" => 1024}
             )

    assert_receive {:mcp_transport, ^pid, {:down, :frame_too_large}}, 1000
    assert {:ok, bad} = start_python("print('not json')")
    assert_receive {:mcp_transport, ^bad, {:down, :invalid_json_rpc_frame}}, 1000
  end

  test "stderr never becomes an RPC frame; outgoing size is bounded" do
    assert {:ok, pid} =
             start_python(
               "import sys,time; print('diagnostic',file=sys.stderr); time.sleep(2)",
               %{"max_message_bytes" => 1024}
             )

    refute_receive {:mcp_transport, ^pid, _}, 100
    MCP.Stdio.send_message(pid, %{"text" => String.duplicate("x", 2000)})
    assert_receive {:mcp_transport, ^pid, {:down, :outgoing_message_too_large}}, 1000
  end

  test "stubborn subprocess is reaped after close and abrupt transport death" do
    for abrupt <- [false, true] do
      assert {:ok, pid} =
               start_python(
                 "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(300)"
               )

      port = :sys.get_state(pid).port
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      # Ensure Python installed its handler so KILL escalation is exercised.
      Process.sleep(100)
      if abrupt, do: Process.exit(pid, :kill), else: MCP.Stdio.close(pid)
      Process.sleep(800)

      case File.read("/proc/#{os_pid}/stat") do
        {:error, :enoent} ->
          :ok

        {:ok, stat} ->
          assert stat |> String.split(") ") |> List.last() |> String.starts_with?("Z ")
      end
    end
  end

  test "missing executable returns a startup error" do
    assert {:error, {:command_not_found, _}} =
             MCP.Stdio.start(%{"command" => "nano-no-such-mcp-command", "args" => []}, self())
  end
end
