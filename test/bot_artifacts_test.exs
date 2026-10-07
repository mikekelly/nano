defmodule Seedling.BotArtifactsTest do
  use ExUnit.Case, async: false
  require Phoenix.LiveViewTest
  alias Seedling.{Bots, BotArtifacts}
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    root_stopped = Supervisor.terminate_child(Nano.Supervisor, Bots) == :ok

    if pid = Process.whereis(Bots),
      do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

    old =
      for key <- [:bots_path, :bot_artifacts_root],
          into: %{},
          do: {key, Application.get_env(:nano, key)}

    Application.put_env(:nano, :bots_path, Path.join(dir, "bots.json"))
    Application.put_env(:nano, :bot_artifacts_root, Path.join(dir, "artifacts"))

    on_exit(fn ->
      if pid = Process.whereis(Bots),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      for {key, value} <- old do
        if value,
          do: Application.put_env(:nano, key, value),
          else: Application.delete_env(:nano, key)
      end

      if root_stopped, do: Supervisor.restart_child(Nano.Supervisor, Bots)
    end)

    {:ok, bot} = Bots.create_bot(%{name: "Maker"})
    {:ok, session} = Bots.create_session([bot["id"]])
    %{bot: bot["id"], session: session["id"], dir: dir}
  end

  test "durable metadata and copied bytes download as attachment only", c do
    path = Path.join(c.dir, "<script>\r\n.html")
    File.write!(path, "<script>alert(1)</script>")
    assert {:ok, msg} = Bots.attach(c.session, c.bot, path)
    assert msg["role"] == "bot"
    assert msg["bot_id"] == c.bot
    assert msg["artifact"]["size"] == 25
    id = msg["artifact"]["id"]
    assert BotArtifacts.valid_id?(id)
    File.write!(path, "changed")
    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, Process.whereis(Bots))
    assert List.last(Bots.session(c.session)["messages"]) == msg

    conn =
      Plug.Test.conn(:get, "/bots/artifacts/#{id}")
      |> NanoWeb.Router.call(NanoWeb.Router.init([]))

    assert conn.status == 200
    assert conn.resp_body == "<script>alert(1)</script>"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [header] = Plug.Conn.get_resp_header(conn, "content-disposition")
    assert String.starts_with?(header, "attachment;")
    refute String.contains?(header, ["\r", "\n", "<"])
  end

  test "invalid membership, missing, directory, symlink and oversized sources", c do
    path = Path.join(c.dir, "source")
    File.write!(path, "ok")
    assert {:error, :invalid_message} = Bots.attach("missing", c.bot, path)
    assert {:error, :invalid_message} = Bots.attach(c.session, "other", path)
    assert {:error, :enoent} = Bots.attach(c.session, c.bot, path <> "missing")
    assert {:error, :not_regular} = Bots.attach(c.session, c.bot, c.dir)
    File.ln_s!(path, path <> "link")
    assert {:error, :symlink} = Bots.attach(c.session, c.bot, path <> "link")
    File.write!(path, :binary.copy("x", 2 * 1024 * 1024 + 1))
    assert {:error, :too_large} = Bots.attach(c.session, c.bot, path)
    assert Bots.session(c.session)["messages"] == []
    assert File.ls!(BotArtifacts.root()) == []
  end

  test "opaque retrieval rejects traversal and symlink artifacts", c do
    for id <- [
          "../bots.json",
          "/etc/passwd",
          "https://example.com",
          "ABC",
          String.duplicate("a", 31)
        ] do
      assert {:error, :invalid_id} = BotArtifacts.fetch(id)
    end

    id = String.duplicate("a", 32)
    File.mkdir_p!(BotArtifacts.root())
    assert {:error, :enoent} = BotArtifacts.fetch(id)
    File.ln_s!(Path.join(c.dir, "bots.json"), Path.join(BotArtifacts.root(), id))
    assert {:error, :symlink} = BotArtifacts.fetch(id)

    conn =
      Plug.Test.conn(:get, "/bots/artifacts/#{id}")
      |> NanoWeb.Router.call(NanoWeb.Router.init([]))

    assert conn.status == 404
  end

  test "attachment link is fixed-origin escaped and invalid metadata has no link" do
    id = String.duplicate("b", 32)

    html =
      Phoenix.LiveViewTest.render_component(&NanoWeb.BotMessage.attachment/1,
        artifact: %{"id" => id, "filename" => "<img onerror=alert(1)>"}
      )

    assert html =~ "/bots/artifacts/#{id}"
    assert html =~ "&lt;img"
    refute html =~ "<img"

    for artifact <- [
          nil,
          %{"id" => "../../etc/passwd", "filename" => "bad"},
          %{"id" => "https://example.com", "filename" => "bad"}
        ] do
      html =
        Phoenix.LiveViewTest.render_component(&NanoWeb.BotMessage.attachment/1,
          artifact: artifact
        )

      refute html =~ "href="
    end
  end

  test "exact cap accepted and symlink ancestors and root rejected", c do
    path = Path.join(c.dir, "source")
    File.write!(path, :binary.copy("x", 2 * 1024 * 1024))
    assert {:ok, msg} = Bots.attach(c.session, c.bot, path)
    assert msg["artifact"]["size"] == 2 * 1024 * 1024
    File.ln_s!(c.dir, Path.join(c.dir, "alias"))
    assert {:error, :symlink} = Bots.attach(c.session, c.bot, Path.join(c.dir, "alias/source"))
    File.rename!(BotArtifacts.root(), Path.join(c.dir, "real-artifacts"))
    File.ln_s!(Path.join(c.dir, "real-artifacts"), BotArtifacts.root())
    assert {:error, :symlink} = BotArtifacts.fetch(msg["artifact"]["id"])
  end

  test "chat persistence failure

 cleans up copied orphan",
       c do
    path = Path.join(c.dir, "source")
    File.write!(path, "ok")
    File.mkdir!(Path.join(c.dir, "bots.json.tmp"))
    assert {:error, _} = Bots.attach(c.session, c.bot, path)
    assert Bots.session(c.session)["messages"] == []
    assert File.ls!(BotArtifacts.root()) == []
  end
end
