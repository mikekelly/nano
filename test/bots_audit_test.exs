defmodule Nano.Bots.AuditTest do
  use ExUnit.Case, async: true
  alias Nano.Bots
  alias NanoWeb.BotsLive

  setup do
    dir = Path.join(System.tmp_dir!(), "altair-audit-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
    on_exit(fn -> File.rm_rf(dir) end)
    store = start_supervised!({Bots.Store, name: nil, store_dir: dir, pubsub: nil})
    opts = [server: store]
    {:ok, bot} = Bots.create_bot(%{name: "Audit"}, opts)
    {:ok, a} = Bots.create_session(%{participant_ids: [bot.id]}, opts)
    {:ok, b} = Bots.create_session(%{participant_ids: [bot.id]}, opts)
    socket = %Phoenix.LiveView.Socket{endpoint: NanoWeb.Endpoint, assigns: %{__changed__: %{}}, private: %{live_temp: %{}}}
    {:ok, socket} = BotsLive.mount(%{}, %{"bots_server" => store}, socket)
    %{opts: opts, bot: bot, a: a, b: b, socket: socket}
  end

  test "navigation must not retain a request from another session", c do
    {:ok, request} = Bots.request_human(%{bot_id: c.bot.id, session_id: c.a.id, requester: "audit-requester", text: "Credential?"}, c.opts)
    {:noreply, s} = BotsLive.handle_info({:bots, :request_created, request}, c.socket)
    {:noreply, s} = BotsLive.handle_params(%{"id" => c.a.id}, "", s)
    {:noreply, s} = BotsLive.handle_event("answer", %{"id" => request.id}, s)
    assert s.assigns.answer_id == request.id
    {:noreply, s} = BotsLive.handle_params(%{"id" => c.b.id}, "", s)
    assert s.assigns.current.id == c.b.id
    assert s.assigns.answer_id == nil
  end

  test "reconnect opens latest conversation page", c do
    for i <- 1..205 do
      {:ok, _} = Bots.post_human(c.a.id, %{text: "message #{i}", idempotency_key: "#{i}"}, c.opts)
    end
    {:noreply, s} = BotsLive.handle_params(%{"id" => c.a.id}, "", c.socket)
    assert List.last(s.assigns.messages).sequence == 205
  end
end
