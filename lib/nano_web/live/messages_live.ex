defmodule NanoWeb.MessagesLive do
  @moduledoc """
  Every user's messages, as one conversation per agent (`Nano.User.threads/1`): on the left
  each user with its conversations, most recent first, and how many are unread; on the
  right, the open one (`?user=<name>&agent=<agent>`; `*` for messages that name no agent),
  both directions in time order, with a box to say something back as that user. Opening a
  conversation marks it read. At phone width the list and the conversation take turns.

  Read from the users' table, never by calling a user, and again whenever a user sends or
  receives anything (PubSub topic `"users"`).
  """
  use Phoenix.LiveView

  import NanoWeb.Components

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "messages", user: nil, agent: nil) |> mount_shared()}
  end

  def handle_params(params, _uri, socket) do
    agent = if params["agent"] == "*", do: nil, else: params["agent"]

    socket
    |> assign(user: params["user"], agent: agent, open: params["agent"] != nil, sent: nil)
    |> load()
    |> then(&{:noreply, &1})
  end

  def handle_info({:nano_user, _}, socket), do: {:noreply, load(socket)}

  def handle_event(event, params, socket) when event in ~w(draft send),
    do: {:noreply, event |> handle_shared(params, socket) |> load()}

  # Users and their conversations; the open one is marked read as it is shown.
  defp load(socket) do
    %{user: user, agent: agent, open: open} = socket.assigns

    users =
      for name <- Enum.sort(Nano.User.list()),
          threads when is_list(threads) <- [Nano.User.threads(name)],
          do: {name, threads}

    thread =
      if open,
        do: Enum.find_value(users, fn {name, ts} -> name == user && find(ts, agent) end)

    if (connected?(socket) and thread) && thread.unread > 0,
      do: Nano.User.mark_read(user, agent)

    socket |> assign(users: users, thread: thread) |> refresh_unread()
  end

  defp find(threads, agent), do: Enum.find(threads, &(&1.agent == agent))

  defp href(user, agent),
    do: "/messages?" <> URI.encode_query(user: user, agent: agent || "*")

  def render(assigns) do
    ~H"""
    <header class="top">
      <h1><.link navigate="/">nano</.link> / messages</h1>
      <.inbox_link unread={@unread} />
    </header>
    <div class={["messages", @open && "open"]}>
      <nav class="threads">
        <p :if={@users == []} class="dim">No users are running.</p>
        <section :for={{name, threads} <- @users} class="user" id={"user-#{name}"}>
          <h2>{name}</h2>
          <p :if={threads == []} class="dim">No messages yet.</p>
          <.link
            :for={t <- threads}
            patch={href(name, t.agent)}
            class={["thread", @open && @user == name && @agent == t.agent && "current"]}
          >
            <span class="with">{t.agent || "no agent"}</span>
            <span :if={t.unread > 0} class="count new">{t.unread}</span>
            <time>{time(List.last(t.messages).at)}</time>
            <span class="last">{preview(List.last(t.messages))}</span>
          </.link>
        </section>
      </nav>

      <section :if={@open} class="conversation">
        <h2>
          <.link patch="/messages" class="back">← all</.link>
          {@user} ⇄ <.link :if={@agent} navigate={"/agents/#{@agent}"}>{@agent}</.link>
          <span :if={!@agent} class="dim">messages that name no agent</span>
        </h2>
        <p :if={!@thread} class="dim">No messages here.</p>
        <ol :if={@thread} id="thread">
          <li :for={m <- @thread.messages} class={["m", m.dir]}>
            <div class="bubble">
              <div :if={said(m)} class="said">{said(m)}</div>
              <.message :if={!said(m)} term={m.term} />
            </div>
            <time>{if m.dir == :sent, do: "sent", else: "received"} {time(m.at)}</time>
          </li>
        </ol>
        <.send_form
          :if={@agent}
          id="reply"
          to={@agent}
          from={@user}
          draft={@draft}
          sent={@sent}
          boxes={["text"]}
          uploads={@uploads}
        />
      </section>
      <p :if={!@open} class="pick dim">Choose a conversation.</p>
    </div>
    """
  end

  # What a user said with `say`: the text alone, without the map around it.
  defp said(%{dir: :sent, term: %{sender_pid: _, message: text}}) when is_binary(text), do: text
  defp said(_), do: nil

  defp preview(m) do
    text = said(m) || inspect(m.term, limit: 5, printable_limit: 80)
    prefix = if m.dir == :sent, do: "you: ", else: ""
    prefix <> String.slice(text, 0, 80)
  end
end
