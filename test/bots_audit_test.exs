defmodule Nano.Bots.AuditTest do
  use ExUnit.Case, async: true
  alias Nano.Bots
  alias NanoWeb.BotsLive

  defmodule NoopAdapter do
    def ensure(_, _, _), do: {:error, :disabled_for_audit}
    def deliver(_, _), do: :ok
    def notify(_, _), do: :ok
    def status(_), do: :idle
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "altair-audit-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    on_exit(fn -> File.rm_rf(dir) end)
    store = start_supervised!({Bots.Store, name: nil, store_dir: dir, pubsub: nil})
    opts = [server: store]
    {:ok, bot} = Bots.create_bot(%{name: "Audit"}, opts)
    {:ok, a} = Bots.create_session(%{participant_ids: [bot.id]}, opts)
    {:ok, b} = Bots.create_session(%{participant_ids: [bot.id]}, opts)

    socket = %Phoenix.LiveView.Socket{
      endpoint: NanoWeb.Endpoint,
      assigns: %{__changed__: %{}},
      private: %{live_temp: %{}}
    }

    {:ok, socket} = BotsLive.mount(%{}, %{"bots_server" => store}, socket)
    %{opts: opts, bot: bot, a: a, b: b, socket: socket, dir: dir}
  end

  test "navigation must not retain a request from another session", c do
    {:ok, request} =
      Bots.request_human(
        %{
          bot_id: c.bot.id,
          session_id: c.a.id,
          requester: "audit-requester",
          text: "Credential?"
        },
        c.opts
      )

    {:noreply, s} = BotsLive.handle_info({:bots, :request_created, request}, c.socket)
    {:noreply, s} = BotsLive.handle_params(%{"id" => c.a.id}, "", s)
    {:noreply, s} = BotsLive.handle_event("answer", %{"id" => request.id}, s)
    assert s.assigns.answer_id == request.id
    {:noreply, s} = BotsLive.handle_params(%{"id" => c.b.id}, "", s)
    assert s.assigns.current.id == c.b.id
    assert s.assigns.answer_id == nil
  end

  test "runtime publication preserves bot-produced attachments", c do
    runtime =
      start_supervised!(
        {Bots.Runtime,
         name: nil,
         store: c.opts[:server],
         state_dir: c.dir <> "/runtime",
         pubsub: nil,
         adapter: NoopAdapter,
         retry_ms: 60_000}
      )

    {:ok, attachment} =
      Bots.Attachments.import_bytes("report",
        store_dir: c.dir <> "/attachments",
        filename: "report.txt"
      )

    assert {:ok, message} =
             Bots.Runtime.post(c.a.id, c.bot.id, "Your report",
               server: runtime,
               epoch: 0,
               idempotency_key: "report",
               attachments: [attachment.ref]
             )

    assert message.attachments == [attachment.ref]
  end

  test "production adapter delivers uploaded image pixels to harness", c do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )

    {:ok, image} = Nano.Images.import_bytes(png)

    {:ok, message} =
      Bots.post_human(
        c.a.id,
        %{
          text: "What is this?",
          idempotency_key: "audit-image",
          attachments: ["image:" <> image.image_ref]
        },
        c.opts
      )

    batch = %{
      session_id: c.a.id,
      bot_id: c.bot.id,
      epoch: message.epoch,
      delivery_id: "audit-image",
      messages: [message]
    }

    Bots.Agent.deliver(self(), batch)
    assert_receive {:"$gen_cast", {:notify, event}}
    {_, visible, _} = Nano.ImageInput.event(event, ["text", "image"])
    assert Enum.any?(visible, &(&1.image_ref == image.image_ref))
  end

  test "reconnect opens latest conversation page", c do
    for i <- 1..205 do
      {:ok, _} = Bots.post_human(c.a.id, %{text: "message #{i}", idempotency_key: "#{i}"}, c.opts)
    end

    {:noreply, s} = BotsLive.handle_params(%{"id" => c.a.id}, "", c.socket)
    assert List.last(s.assigns.messages).sequence == 205
  end
end
