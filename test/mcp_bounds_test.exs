defmodule Nano.MCPBoundsTest do
  use ExUnit.Case, async: true
  alias Nano.MCP
  alias Nano.MCP.Result

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nova-mcp-bounds-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "invalid budgets, offsets and paths return errors without raising", %{dir: dir} do
    for bad <- [0, -1, 1.5, "100", nil, :infinity] do
      assert {:error, :invalid_options} = Result.bound(%{}, max_bytes: bad)
      assert {:error, :invalid_options} = Result.page(Path.join(dir, "unused"), limit: bad)
      assert {:error, :invalid_options} = MCP.request("unused", "ping", %{}, max_bytes: bad)
    end

    for bad <- [-1, 1.5, "100", nil] do
      assert {:error, :invalid_options} = Result.page(Path.join(dir, "unused"), offset: bad)
    end

    assert {:error, :invalid_options} = Result.bound(%{}, "opts")
    assert {:error, :invalid_options} = Result.bound(%{}, spill_dir: <<0>>)
    assert {:error, :invalid_options} = MCP.tools("unused", timeout: "huge")
    assert {:error, :invalid_options} = MCP.connect("invalid", recipient: %{})
    assert {:error, :invalid_subscription} = MCP.subscribe("unused", nil)
    assert {:error, :invalid_recipient} = MCP.watch("unused", %{})
  end

  test "hard inspected-output budgets hold for large, unicode and binary results", %{dir: dir} do
    for result <- [
          List.duplicate(%{"value" => "\u0080"}, 10_000),
          %{"blob" => Base.encode64(:crypto.strong_rand_bytes(100_000))},
          %{"text" => String.duplicate("🙂", 20_000)}
        ] do
      assert {:ok, %{spilled: true, path: path, preview: preview} = summary} =
               Result.bound(result, max_bytes: 1_000_000, spill_dir: dir)

      assert String.valid?(preview)
      assert byte_size(inspect(summary, limit: :infinity, printable_limit: :infinity)) < 35_000
      assert Jason.decode!(File.read!(path)) == result
      assert {:ok, %{data: page} = paged} = Result.page(path, limit: 1_000_000)
      assert byte_size(page) <= 4_096
      assert byte_size(inspect(paged, limit: :infinity, printable_limit: :infinity)) < 35_000
      assert {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    binary_path = Path.join(dir, "binary")
    File.write!(binary_path, :binary.copy(<<255, 0, 1, 2, 3, 4>>, 10_000))
    assert {:ok, page} = Result.page(binary_path, limit: 100_000)
    assert byte_size(inspect(page, limit: :infinity, printable_limit: :infinity)) < 35_000
  end

  test "malformed transports and credential-bearing descriptors are rejected without reflection",
       %{dir: dir} do
    bad = [
      nil,
      %{},
      %{"command" => 5},
      %{"command" => "python3", "args" => "bad"},
      %{"command" => "python3", "env" => %{"KEY" => :secret}},
      %{"url" => "ftp://example.invalid"},
      %{"url" => "https://example.invalid", "headers" => %{"Authorization" => :secret}},
      %{"command" => "x", "url" => "https://example.invalid"},
      %{"url" => "https://example.invalid", "receive_timeout" => -1}
    ]

    for config <- bad do
      assert {:error, reason} = MCP.connect("bad", config: config)
      assert is_atom(reason)
    end

    path = Path.join(dir, "malformed.json")
    File.write!(path, Jason.encode!(%{"mcpServers" => %{"bad" => %{"command" => 4}}}))
    assert {:error, :invalid_server_config} = MCP.load_config(path)
    File.write!(path, ~s({"Authorization":"not-a-secret-but-must-not-reflect",))
    assert {:error, :invalid_json} = MCP.load_config(path)

    assert :ok =
             MCP.validate_config(%{
               "command" => "python3",
               "args" => ["-c", ""],
               "env" => %{"KEY" => "${SAFE_KEY}"}
             })
  end
end
