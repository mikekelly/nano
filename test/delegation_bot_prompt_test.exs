defmodule Delegation.BotPromptTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "altair-bot-prompt-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp opts,
    do: [
      name: "bot",
      parent: "runtime",
      level: :engineering,
      flavours: ["bot"],
      job: "Use Runtime.post to chat"
    ]

  test "default composition identical, consumer retains whole seed and principles", %{dir: dir} do
    {:ok, default} = Delegation.Prompt.compose(opts())
    {:ok, explicit} = Delegation.Prompt.compose(opts() ++ [mode: :worker])
    assert default == explicit
    assert default.prompt =~ "Delegation.report(\"bot\", result)"
    assert default.prompt =~ "This job is read-only"
    {:ok, chat} = Delegation.Prompt.compose(opts() ++ [mode: :consumer, workspace: dir])
    seed = File.read!(Path.expand("../prompts/seed.txt", __DIR__))
    assert String.starts_with?(chat.prompt, seed)
    assert chat.provenance.seed == default.provenance.seed
    assert chat.provenance.partials == default.provenance.partials
    assert chat.prompt =~ "preserving this composition rule"
    assert chat.prompt =~ "Use Runtime.post to chat"
    assert chat.prompt =~ "explicitly use the runtime publication protocol"
    assert chat.prompt =~ inspect(dir)
    assert chat.prompt =~ "not an OS sandbox"
    refute chat.prompt =~ "Delegation.report(\"bot\", result)"
    refute chat.prompt =~ "This job is read-only"

    assert chat.provenance.composed_sha256 ==
             Base.encode16(:crypto.hash(:sha256, chat.prompt), case: :lower)
  end

  test "no workspace is not a false isolation claim" do
    {:ok, chat} = Delegation.Prompt.compose(opts() ++ [mode: :consumer])
    assert chat.prompt =~ "No workspace directory was assigned"
    refute chat.prompt =~ "Your persistent bot/session workspace directory is"
  end

  test "invalid paths and modes rejected", %{dir: dir} do
    file = Path.join(dir, "file")
    File.write!(file, "data")
    symlink = Path.join(dir, "link")
    File.ln_s!(dir, symlink)

    for workspace <- [
          "relative",
          "/",
          file,
          symlink,
          Path.join(symlink, "child"),
          Path.join(dir, "missing"),
          dir <> "\n",
          12
        ] do
      assert {:error, _} =
               Delegation.Prompt.compose(opts() ++ [mode: :consumer, workspace: workspace])
    end

    assert {:error, _} = Delegation.Prompt.compose(opts() ++ [mode: :invalid])
  end
end
