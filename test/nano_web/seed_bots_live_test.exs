defmodule NanoWeb.SeedBotsLiveTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias NanoWeb.SeedBotsLive, as: View

  defp assigns do
    bot = %{id: "b1", name: "Muse", description: "Partner", color: "#818cf8"}

    %{
      bots: [bot, %{bot | id: "b2", name: "Scout"}],
      sessions: [],
      current: nil,
      selected: [],
      query: "",
      search: "",
      draft: "",
      creating: false,
      error: nil,
      notice: nil,
      notifications: false,
      statuses: %{},
      requests: %{}
    }
  end

  defp socket(attrs \\ %{}) do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, Map.merge(assigns(), attrs))
  end

  test "human requests have answer forms only while pending; status and stop controls are visible" do
    message = %{id: "m1", author: :system, text: "Please choose", request_id: "r1"}
    session = %{id: "s1", title: "Muse", bot_ids: ["b1"], messages: [message]}

    a =
      Map.merge(assigns(), %{
        current: session,
        sessions: [session],
        statuses: %{"b1" => :thinking},
        requests: %{"r1" => %{status: :pending}}
      })

    html = render_component(&View.render/1, a)
    assert html =~ "Send answer"
    assert html =~ "thinking…"
    assert html =~ "Stop replies"
    assert html =~ "Chat update"
    html = render_component(&View.render/1, %{a | requests: %{"r1" => %{status: :answered}}})
    refute html =~ "Send answer"

    {:noreply, s} =
      View.handle_event(
        "answer",
        %{"request_id" => "not-in-chat", "answer" => "Yes"},
        socket(%{current: session})
      )

    assert s.assigns.error =~ "open request"
  end

  test "empty state offers search, bot creation and accessible messaging" do
    html = render_component(&View.render/1, assigns())
    assert html =~ "Search chats"
    assert html =~ "Create new bot"
    assert html =~ "Write your first message"
    assert html =~ "aria-label=\"Send message\""
    refute html =~ "/api/eval"
  end

  test "model content, bot identity and CSS colors are never trusted HTML" do
    attack = "<script>alert('x')</script><img src=x onerror=alert(1)>"

    bot = %{
      id: "evil",
      name: attack,
      description: attack,
      color: "red; background:url(javascript:alert(1))"
    }

    session = %{
      id: "s1",
      title: attack,
      bot_ids: [bot.id],
      messages: [
        %{
          id: "m1",
          author: bot.id,
          text: attack <> "\n```elixir\nIO.puts(1)\n```",
          inserted_at: nil
        },
        %{id: "m2", author: :user, text: "Hello", inserted_at: nil}
      ]
    }

    html =
      render_component(
        &View.render/1,
        Map.merge(assigns(), %{bots: [bot], sessions: [session], current: session})
      )

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ "<img"
    refute html =~ "javascript:"
    assert html =~ "IO.puts(1)"
    assert html =~ "sb-message user"
    assert html =~ "background: #818cf8"
  end

  test "selection creates unique removable chips and rejects stale bot IDs" do
    {:noreply, s} = View.handle_event("select", %{"id" => "b1"}, socket())
    {:noreply, s} = View.handle_event("select", %{"id" => "b1"}, s)
    {:noreply, s} = View.handle_event("select", %{"id" => "b2"}, s)
    assert s.assigns.selected == ["b1", "b2"]
    html = render_component(&View.render/1, s.assigns)
    assert html =~ "Remove Muse"
    assert html =~ "Remove Scout"
    {:noreply, s} = View.handle_event("remove", %{"id" => "b1"}, s)
    assert s.assigns.selected == ["b2"]
    {:noreply, s} = View.handle_event("select", %{"id" => "missing"}, s)
    assert s.assigns.error =~ "no longer available"
    assert s.assigns.selected == ["b2"]
  end

  test "case insensitive picker and session search" do
    a =
      Map.merge(assigns(), %{
        query: "muSE",
        search: "holiday",
        sessions: [
          %{id: "s1", title: "Holiday plans", bot_ids: ["b1"], messages: []},
          %{id: "s2", title: "Work", bot_ids: ["b2"], messages: []}
        ]
      })

    html = render_component(&View.render/1, a)
    assert html =~ "Holiday plans"
    refute html =~ ">Work<"
    assert html =~ "phx-value-id=\"b1\""
    refute html =~ "phx-value-id=\"b2\""
  end

  test "validation saves draft and starting over clears old selection" do
    {:noreply, s} = View.handle_event("send", %{"text" => "  "}, socket())
    assert s.assigns.error == "Write a message first."
    {:noreply, s} = View.handle_event("send", %{"text" => "Hello"}, s)
    assert s.assigns.draft == "Hello"
    assert s.assigns.error =~ "Choose at least one bot"
    {:noreply, s} = View.handle_event("new-chat", %{}, s)
    assert s.assigns.draft == ""
    assert s.assigns.selected == []
    assert s.assigns.error == nil
  end

  test "opening an existing chat and toggling notification preference" do
    session = %{id: "s1", title: "Muse", bot_ids: ["b1"], messages: []}
    {:noreply, s} = View.handle_event("open", %{"id" => "s1"}, socket(%{sessions: [session]}))
    assert s.assigns.current == session
    {:noreply, s} = View.handle_event("notifications", %{}, s)
    assert s.assigns.notifications
    {:noreply, s} = View.handle_event("notifications", %{}, s)
    refute s.assigns.notifications
    {:noreply, s} = View.handle_event("open", %{"id" => "stale"}, s)
    assert s.assigns.current == session
    assert s.assigns.error =~ "no longer available"
  end
end
