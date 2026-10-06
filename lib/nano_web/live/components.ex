defmodule NanoWeb.Components do
  @moduledoc """
  What both dashboard pages share: the send forms, the `dashboard` user's inbox, agent status
  badges, and formatting. Presentation only; every send goes through `Nano.User` and every
  term through `Nano.Ops.term/1`, exactly as the HTTP API does.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @user "dashboard"
  @inspect [pretty: true, limit: 100, printable_limit: 4096]

  ## State and events shared by both LiveViews

  @doc "Assigns the send-form drafts and the dashboard user's inbox; subscribes to its traffic."
  def mount_shared(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: Phoenix.PubSub.subscribe(Nano.PubSub, "user:" <> @user)

    socket
    |> assign(draft: %{"text" => "", "term" => ""}, sent: nil)
    |> refresh_inbox()
  end

  @doc "Re-reads the dashboard user's inbox (newest first; nil if the user is not running or not answering)."
  def refresh_inbox(socket) do
    inbox =
      case Nano.User.inbox(@user) do
        messages when is_list(messages) -> Enum.reverse(messages)
        {:error, _} -> nil
      end

    assign(socket, inbox: inbox, inbox_pid: Nano.User.pid(@user))
  end

  @doc """
  Handles the shared events: `"draft"` (a send form changed), `"send"` (the text box goes
  through `Nano.User.say/3`, the term box through `Nano.Ops.term/1` and `Nano.User.send_raw/3`),
  and `"clear_inbox"`.
  """
  def handle_shared("draft", params, socket),
    do: assign(socket, draft: Map.merge(socket.assigns.draft, Map.take(params, ~w(text term))))

  def handle_shared("send", %{"to" => to, "text" => text}, socket) do
    sent = result(Nano.User.say(@user, to, text), "said #{inspect(text)} to #{to}")
    sent(socket, sent, "text")
  end

  def handle_shared("send", %{"to" => to, "term" => code}, socket) do
    sent =
      case Nano.Ops.term(code) do
        {:ok, term} ->
          result(Nano.User.send_raw(@user, to, term), "sent #{show(term)} to #{to}")

        {:error, message} ->
          {:error, message}
      end

    sent(socket, sent, "term")
  end

  def handle_shared("clear_inbox", _params, socket) do
    Nano.User.inbox(@user, clear: true)
    refresh_inbox(socket)
  end

  # A successful send empties its box; a failed one keeps it for fixing.
  defp sent(socket, {:ok, _} = sent, box),
    do: assign(socket, sent: sent, draft: Map.put(socket.assigns.draft, box, ""))

  defp sent(socket, sent, _box), do: assign(socket, sent: sent)

  defp result(:ok, message), do: {:ok, message}
  defp result({:error, :unknown_target}, _), do: {:error, "no such process (it may have exited)"}
  defp result({:error, :unknown_user}, _), do: {:error, "the #{@user} user is not running"}

  defp result({:error, :unresponsive}, _),
    do: {:error, "the #{@user} user is not responding (suspended or flooded?); nothing was sent"}

  defp result({:error, reason}, _), do: {:error, inspect(reason)}

  ## Components

  attr :id, :string, required: true
  attr :to, :string, required: true, doc: "target: a pid string or an agent name"
  attr :draft, :map, required: true
  attr :sent, :any, required: true

  @doc "The send form: a plain-text box (`say/3`) and an Elixir term box (`send_raw/3`)."
  def send_form(assigns) do
    ~H"""
    <div class="send" id={@id}>
      <form id={@id <> "-text"} phx-change="draft" phx-submit="send">
        <input type="hidden" name="to" value={@to} />
        <input
          type="text"
          name="text"
          value={@draft["text"]}
          placeholder="plain text, sent as %{sender_pid: dashboard, message: text}"
          autocomplete="off"
        />
        <button>say</button>
      </form>
      <form id={@id <> "-term"} phx-change="draft" phx-submit="send">
        <input type="hidden" name="to" value={@to} />
        <input
          type="text"
          name="term"
          value={@draft["term"]}
          placeholder={
            ~s|Elixir term, sent as is: {:hello, Nano.User.pid("dashboard"), "are you there?"}|
          }
          autocomplete="off"
          class="mono"
        />
        <button>send term</button>
      </form>
      <p :if={@sent} class={["sent", elem(@sent, 0)]}>{elem(@sent, 1)}</p>
    </div>
    """
  end

  attr :inbox, :any, required: true
  attr :pid, :any, required: true

  @doc "The dashboard user's inbox: replies to anything sent from these forms."
  def inbox(assigns) do
    ~H"""
    <section class="inbox">
      <h2>
        inbox of user "dashboard" <span class="dim">{@pid && inspect(@pid)}</span>
        <button :if={@inbox not in [nil, []]} phx-click="clear_inbox" class="small">clear</button>
      </h2>
      <p :if={@inbox == nil} class="error">
        {if @pid,
          do:
            "The dashboard user is not responding (suspended or flooded?), so its inbox cannot be read.",
          else: "The dashboard user is not running."}
      </p>
      <p :if={@inbox == []} class="dim">
        Nothing received yet. Messages sent with "say" carry this user's pid; in a term, use <code>Nano.User.pid("dashboard")</code>.
      </p>
      <ol :if={@inbox} id="inbox">
        <li :for={m <- Enum.take(@inbox, 50)}>
          <time>{time(m.at)}</time>
          <pre>{show(m.term)}</pre>
        </li>
      </ol>
    </section>
    """
  end

  attr :agent, :map, required: true

  @doc "An agent's state as badges: idle / thinking / running_tool, plus suspended, halted, down."
  def status(assigns) do
    ~H"""
    <span class="badges">
      <span :if={@agent.pid == nil} class="badge down">down</span>
      <span :if={@agent.pid} class={["badge", @agent.status]}>{@agent.status}</span>
      <span :if={@agent.suspended} class="badge suspended">suspended</span>
      <span :if={@agent.halted} class="badge halted">halted: {@agent.halted}</span>
    </span>
    """
  end

  attr :code, :string, required: true

  @doc "Elixir source in a `<pre>`, with comments, strings, atoms, modules, numbers and keywords marked."
  def code(assigns) do
    ~H"""
    <pre class="code"><span :for={{class, text} <- tokens(String.trim(@code, "\n"))} class={class}>{text}</span></pre>
    """
  end

  @token ~r/#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|:[a-zA-Z_]\w*[?!]?|\b[a-z_]\w*[?!]?:(?=\s)|\b[A-Z]\w*(?:\.[A-Z]\w*)*|\b\d[\d_]*(?:\.\d+)?\b|\b(?:defp?|defmodule|do|end|fn|if|else|unless|case|cond|with|for|receive|after|when|in|and|or|not|true|false|nil|try|rescue|catch|raise)\b/

  @doc false
  # Split keeps matches at odd positions, plain text at even ones.
  def tokens(code) do
    @token
    |> Regex.split(code, include_captures: true)
    |> Enum.with_index()
    |> Enum.map(fn {text, i} -> {if(rem(i, 2) == 1, do: token_class(text)), text} end)
  end

  defp token_class("#" <> _), do: "cm"
  defp token_class(<<q, _::binary>>) when q in [?", ?'], do: "st"
  defp token_class(":" <> _), do: "at"
  defp token_class(<<c, _::binary>>) when c in ?A..?Z, do: "md"
  defp token_class(<<c, _::binary>>) when c in ?0..?9, do: "nm"
  defp token_class(text), do: if(String.ends_with?(text, ":"), do: "at", else: "kw")

  @doc "Keeps a `<details>` element's open/closed state across the page's periodic re-renders."
  def keep_open, do: JS.ignore_attributes("open")

  ## Formatting

  def time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_time()

  def time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> time(at)
      _ -> iso
    end
  end

  def time(_), do: ""

  @doc "A term as Elixir source, bounded."
  def show(term), do: inspect(term, @inspect)

  def mfa({m, f, a}), do: Exception.format_mfa(m, f, a)
  def mfa(other), do: inspect(other)

  def bytes(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  def bytes(n) when n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def bytes(n), do: "#{n} B"

  @doc """
  Any logged value as display text: a string as it is, anything else as Elixir source. Log
  fields can hold whatever a model or provider sent, so the pages render them through this.
  """
  def txt(nil), do: ""
  def txt(value) when is_binary(value), do: value
  def txt(value) when is_number(value) or is_atom(value), do: to_string(value)
  def txt(value), do: show(value)

  def int(nil), do: "–"

  def int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+$)/, ",")
  end

  def int(n), do: txt(n)

  def cost(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 4)
  def cost(nil), do: "–"
  def cost(n), do: txt(n)

  def percent(rate) when is_number(rate), do: "#{round(rate * 100)}%"
  def percent(_), do: "–"
end
