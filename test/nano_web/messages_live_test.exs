defmodule NanoWeb.MessagesLiveTest do
  # Not async: a message that names no agent is put with the one agent running an eval, if
  # one is, and agents of async tests may be.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nano.User

  @endpoint NanoWeb.Endpoint

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  setup do
    name = unique("u")
    user = User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, user) end)

    # A process registered as an agent, standing in for NanoAgent, that forwards what it gets.
    agent = unique("agent")
    test = self()

    agent_pid =
      spawn_link(fn ->
        Nano.Names.register_name({:agent, agent}, self())
        send(test, :registered)
        forward(test)
      end)

    assert_receive :registered
    %{name: name, user: user, agent: agent, agent_pid: agent_pid, conn: build_conn()}
  end

  defp forward(test) do
    receive do
      msg -> send(test, {:forwarded, msg})
    end

    forward(test)
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # The open conversation, as {direction, text} per message, exactly as shown.
  defp conversation(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".conversation li.m")
    |> Enum.map(fn li ->
      {hd(LazyHTML.attribute(li, "class")),
       String.trim(LazyHTML.text(LazyHTML.query(li, ".bubble")))}
    end)
  end

  defp unread(name, agent), do: Enum.find(User.threads(name), &(&1.agent == agent)).unread

  test "every user's conversations, one per agent, both directions in time order", ctx do
    %{name: name, user: user, agent: agent} = ctx
    :ok = User.say(name, agent, "hello\nthere")
    send(user, {:reply, ctx.agent_pid, "first line\nsecond line"})
    :ok = User.send_raw(name, agent, {:ping, 1})

    {:ok, view, _} = live(ctx.conn, "/messages")
    assert has_element?(view, "header.top #inbox-link")
    link = "#user-#{name} a.thread[href='/messages?user=#{name}&agent=#{agent}']"
    assert has_element?(view, link, agent)
    assert has_element?(view, link <> " .count.new", "1")
    assert has_element?(view, link <> " .last", "you: {:ping, 1}")
    refute has_element?(view, ".conversation")

    view |> element(link) |> render_click()
    assert_patch(view, "/messages?user=#{name}&agent=#{agent}")
    assert has_element?(view, ".messages.open")
    assert has_element?(view, ".conversation h2 a[href='/agents/#{agent}']", agent)

    # What the user said is its text, line break and all; a term is made readable.
    assert [
             {"m sent", "hello\nthere"},
             {"m received", received},
             {"m sent", "{:ping, 1}"}
           ] = conversation(view)

    assert received =~ "first line\nsecond line"
    # Shown, so read.
    eventually(fn -> unread(name, agent) == 0 end)
    eventually(fn -> !has_element?(view, link <> " .count") end)

    # Saying something back goes out as this user, and joins the conversation.
    view |> form("#reply-text", %{text: "thanks"}) |> render_submit()
    assert_receive {:forwarded, %{sender_pid: ^user, message: "thanks"}}
    assert has_element?(view, "#reply input[name=text][value='']")

    # Live: an arriving reply shows, and is read at once since the conversation is open.
    send(user, {:done, ctx.agent_pid})
    eventually(fn -> length(conversation(view)) == 5 end)
    assert [_, _, _, {"m sent", "thanks"}, {"m received", "{:done, " <> _}] = conversation(view)
    eventually(fn -> unread(name, agent) == 0 end)
  end

  test "messages that name no agent have their own conversation", ctx do
    send(ctx.user, {:anonymous, "who sent this?"})
    eventually(fn -> match?([%{agent: nil}], User.threads(ctx.name)) end)

    {:ok, view, _} = live(ctx.conn, "/messages?user=#{ctx.name}&agent=*")
    assert has_element?(view, "a.thread.current .with", "no agent")
    assert has_element?(view, ".conversation h2", "messages that name no agent")
    assert has_element?(view, ".conversation li.m.received .summary", "who sent this?")
    # There is no agent to say anything back to.
    refute has_element?(view, "#reply")
  end

  test "an unknown conversation says so; the unread count follows on every page", ctx do
    {:ok, view, _} = live(ctx.conn, "/messages?user=#{ctx.name}&agent=nobody")
    assert has_element?(view, ".conversation", "No messages here.")

    {:ok, home, _} = live(ctx.conn, "/")
    before = User.list() |> Enum.flat_map(&User.threads/1) |> Enum.map(& &1.unread) |> Enum.sum()
    send(ctx.user, {:reply, ctx.agent_pid, "news"})

    eventually(fn ->
      has_element?(home, "#inbox-link .count.new", to_string(before + 1)) and
        has_element?(view, "#inbox-link .count.new", to_string(before + 1))
    end)
  end
end
