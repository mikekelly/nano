defmodule NanoWeb.SeedBotsIntegrationTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias NanoWeb.SeedBotsLive, as: View

  setup do
    dir = Path.join(System.tmp_dir!(), "seed-bots-ui-#{System.unique_integer([:positive])}")
    start_supervised!({SeedBots, directory: dir, agents: false, routing: false})
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "two identities, direct and group sessions, published replies and human answers" do
    {:ok, socket} = View.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      View.handle_event(
        "create-bot",
        %{"bot" => %{"name" => "Muse", "description" => "Creative"}},
        socket
      )

    first = hd(socket.assigns.bots)
    {:noreply, socket} = View.handle_event("send", %{"text" => "Hello Muse"}, socket)
    direct = socket.assigns.current
    assert direct.bot_ids == [first.id]
    {:noreply, socket} = View.handle_event("new-chat", %{}, socket)

    {:noreply, socket} =
      View.handle_event(
        "create-bot",
        %{"bot" => %{"name" => "Scout", "description" => "Curious"}},
        socket
      )

    second = Enum.find(socket.assigns.bots, &(&1.id != first.id))
    {:noreply, socket} = View.handle_event("select", %{"id" => first.id}, socket)
    {:noreply, socket} = View.handle_event("send", %{"text" => "Plan together"}, socket)
    group = socket.assigns.current
    assert Enum.sort(group.bot_ids) == Enum.sort([first.id, second.id])
    {:ok, _} = SeedBots.speak(group.id, first.id, "An idea <script>bad()</script>")
    {:noreply, socket} = View.handle_info({:seed_bots, :changed}, socket)
    html = render_component(&View.render/1, socket.assigns)
    assert html =~ "An idea &lt;script&gt;"
    refute html =~ "<script>bad"
    assert length(SeedBots.get_session(direct.id).messages) == 1
    {:ok, request} = SeedBots.ask_human(group.id, second.id, "Which day?")
    {:noreply, socket} = View.handle_info({:seed_bots, :changed}, socket)
    assert render_component(&View.render/1, socket.assigns) =~ "Answer request"

    {:noreply, socket} =
      View.handle_event("answer", %{"request" => request, "text" => "Tuesday"}, socket)

    assert_receive {:seed_bots_answer, ^request, "Tuesday"}
    assert SeedBots.request(request).status == :answered
    refute render_component(&View.render/1, socket.assigns) =~ "Answer request"
    assert render_component(&View.render/1, socket.assigns) =~ "Tuesday"
  end
end
