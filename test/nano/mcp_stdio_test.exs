defmodule Nano.MCP.StdioTest do
  use ExUnit.Case, async: true
  alias Nano.MCP.Stdio
  @fixture Path.expand("../fixtures/mcp_stdio.py", __DIR__)

  defp start(mode, extra \\ %{}) do
    config = Map.merge(%{"command" => "python3", "args" => [@fixture, mode]}, extra)
    {:ok, pid} = Stdio.start_link(self(), config)
    Process.unlink(pid)
    on_exit(fn -> Stdio.stop(pid) end)
    pid
  end

  test "stderr is separate, split UTF-8 and escaped newlines round trip" do
    pid = start("split")
    msg = %{"jsonrpc" => "2.0", "id" => 1, "result" => "héllo\n世界"}
    assert :ok = Stdio.send_message(pid, msg)
    assert_receive {:mcp_transport, ^pid, {:message, ^msg}}, 2000
    assert :ok = Stdio.stop(pid)
    assert_receive {:mcp_transport, ^pid, {:down, :normal}}
    refute_receive {:mcp_transport, ^pid, _}
  end

  test "multiple frames in one write" do
    pid = start("multi")
    msg = %{"id" => 2}
    assert :ok = Stdio.send_message(pid, msg)
    assert_receive {:mcp_transport, ^pid, {:message, ^msg}}, 1000
    assert_receive {:mcp_transport, ^pid, {:message, ^msg}}, 1000
  end

  test "direct argv, environment override and cwd" do
    cwd = System.tmp_dir!()

    pid =
      start("context", %{
        "args" => [@fixture, "context", "literal ; $HOME"],
        "cwd" => cwd,
        "env" => %{"MCP_TEST_VALUE" => "resolved"}
      })

    assert :ok = Stdio.send_message(pid, %{})
    assert_receive {:mcp_transport, ^pid, {:message, msg}}, 1000
    assert msg == %{"cwd" => cwd, "env" => "resolved", "arg" => "literal ; $HOME"}
  end

  test "fail closed with exactly one down event" do
    for {mode, reason} <- [
          {"invalid", :invalid_json_message},
          {"array", :invalid_json_message},
          {"huge", :message_too_large},
          {"partial", :unterminated_frame},
          {"exit", {:exit_status, 7}}
        ] do
      pid = start(mode, %{"max_message_bytes" => 100})
      assert_receive {:mcp_transport, ^pid, {:down, ^reason}}, 2000
      refute_receive {:mcp_transport, ^pid, _}
    end
  end

  test "outbound limit rejects without closing" do
    pid = start("echo", %{"max_message_bytes" => 20})

    assert {:error, :message_too_large} =
             Stdio.send_message(pid, %{"x" => String.duplicate("a", 20)})

    assert :ok = Stdio.send_message(pid, %{})
    assert_receive {:mcp_transport, ^pid, {:message, %{}}}, 1000
  end

  test "owner death closes transport" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid} = Stdio.start_link(owner, %{"command" => "python3", "args" => [@fixture, "echo"]})
    ref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
  end

  test "shutdown escalates for child ignoring EOF and SIGTERM" do
    pid = start("stubborn")
    assert_receive {:mcp_transport, ^pid, {:message, %{"pid" => os_pid}}}, 1000
    assert :ok = Stdio.stop(pid)
    Process.sleep(100)

    {_, status} =
      System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert status != 0
  end

  @tag :reference
  @tag skip:
         is_nil(System.get_env("MCP_REFERENCE_NODE")) or
           is_nil(System.get_env("MCP_REFERENCE_FILESYSTEM"))
  test "real reference filesystem server initializes, lists tools and reads a file" do
    node = System.get_env("MCP_REFERENCE_NODE")
    server = System.get_env("MCP_REFERENCE_FILESYSTEM")

    if node && server do
      dir =
        Path.join(
          System.tmp_dir!(),
          "altair-mcp-reference-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
        )

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "hello.txt"), "reference transport works")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, pid} = Stdio.start_link(self(), %{"command" => node, "args" => [server, dir]})
      Process.unlink(pid)
      on_exit(fn -> Stdio.stop(pid) end)

      :ok =
        Stdio.send_message(pid, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "nano-test", "version" => "1"}
          }
        })

      assert_receive {:mcp_transport, ^pid, {:message, %{"id" => 1, "result" => result}}}, 5000
      assert is_binary(result["protocolVersion"])

      :ok =
        Stdio.send_message(pid, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      :ok = Stdio.send_message(pid, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      assert_receive {:mcp_transport, ^pid,
                      {:message, %{"id" => 2, "result" => %{"tools" => tools}}}},
                     5000

      assert Enum.any?(tools, &(&1["name"] == "read_text_file"))

      :ok =
        Stdio.send_message(pid, %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "read_text_file",
            "arguments" => %{"path" => Path.join(dir, "hello.txt")}
          }
        })

      assert_receive {:mcp_transport, ^pid, {:message, %{"id" => 3, "result" => read}}}, 5000
      assert Enum.any?(read["content"], &(&1["text"] == "reference transport works"))
    else
      IO.puts(
        "Reference filesystem check not run: set MCP_REFERENCE_NODE and MCP_REFERENCE_FILESYSTEM"
      )
    end
  end
end
