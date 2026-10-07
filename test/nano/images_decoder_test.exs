defmodule Vega.ImagesDecoderTest do
  use ExUnit.Case, async: false
  alias Vega.Images

  setup do
    old = Application.get_env(:nano, :image_decoder_python)

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :image_decoder_python, old),
        else: Application.delete_env(:nano, :image_decoder_python)
    end)
  end

  defp temp_entries do
    root = Path.join(Application.fetch_env!(:nano, :state_dir), "images")

    File.ls!(root)
    |> Enum.filter(
      &(String.starts_with?(&1, ".validate-") or String.starts_with?(&1, ".upload-"))
    )
  end

  test "decoder unavailable fails closed, leaving no raw temp files or stored image" do
    Application.put_env(:nano, :image_decoder_python, "/does/not/exist")
    bytes = Nano.ImageFixture.png(31, 39)
    assert {:error, reason} = Images.import_bytes(bytes)
    assert reason =~ "decoder unavailable"
    assert temp_entries() == []
    id = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    refute File.exists?(Path.join([Application.fetch_env!(:nano, :state_dir), "images", id]))
  end

  test "successful hash verification is cached once and concurrent imports leave no temporary bytes" do
    bytes = Nano.ImageFixture.png(43, 47)
    assert {:ok, ref} = Images.import_bytes(bytes)
    Application.put_env(:nano, :image_decoder_python, "/does/not/exist")
    assert {:ok, ^bytes, "image/png"} = Images.fetch(ref["id"])

    results =
      1..16
      |> Task.async_stream(fn _ -> Images.import_bytes(bytes) end, max_concurrency: 16)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert temp_entries() == []
  end

  test "stalled decoder is killed within bound with private temp cleanup" do
    script =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "decoder-stall-#{System.unique_integer([:positive])}"
      )

    File.write!(script, "#!/bin/sh\nexec /bin/sleep 20\n")
    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm(script) end)
    Application.put_env(:nano, :image_decoder_python, script)
    start = System.monotonic_time(:millisecond)
    assert {:error, reason} = Images.import_bytes(Nano.ImageFixture.png(32, 41))
    assert reason =~ "resource limit"
    assert System.monotonic_time(:millisecond) - start < 8000
    assert temp_entries() == []
  end
end
