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
    do:
      {:error,
       "the #{@user} user is not responding (suspended or flooded?); the message is queued " <>
         "in its mailbox and will go out if it resumes, so sending again would send it twice"}

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

  @doc """
  The dashboard user's inbox, behind an icon fixed at the top right: replies to anything sent
  from these forms, newest first. The count of messages new since this viewer last opened it
  is kept in their browser (the InboxSeen hook).
  """
  def inbox_menu(assigns) do
    ~H"""
    <details
      id="inbox-menu"
      class="dropdown inbox-menu"
      phx-mounted={keep_open()}
      phx-hook="InboxSeen"
    >
      <summary title="inbox of user dashboard">
        <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
          <path
            d="M3 6.5h18v11H3z M3 7l9 6.5L21 7"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linejoin="round"
          />
        </svg>
        <span :if={@inbox not in [nil, []]} class="count">{length(@inbox)}</span>
        <span :if={@inbox == nil} class="count warn">!</span>
        <span id="inbox-new" class="count new" phx-update="ignore" hidden></span>
      </summary>
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
          <li :for={m <- Enum.take(@inbox, 50)} data-at={DateTime.to_iso8601(m.at)}>
            <time>{time(m.at)}</time>
            <.message term={m.term} />
          </li>
        </ol>
        <p :if={@inbox && length(@inbox) > 50} class="dim">{length(@inbox) - 50} older not shown.</p>
      </section>
    </details>
    """
  end

  attr :term, :any, required: true

  @doc """
  A message term made readable: a one-line summary of its structure, then each long or
  multi-line string found in it as wrapped text, labelled with where it sat. A message that
  is just a string is shown as text.
  """
  def message(assigns) do
    assigns = assign(assigns, summary: summary(assigns.term), texts: texts(assigns.term))

    ~H"""
    <code :if={@summary} class="summary">{@summary}</code>
    <div :for={{where, text} <- @texts} class="text">
      <span :if={where} class="where">{where}</span>
      <div class="body">{text}</div>
    </div>
    """
  end

  defp summary(term) when is_binary(term) and byte_size(term) < 4096 do
    if String.valid?(term),
      do: nil,
      else: clip(inspect(term, limit: 12, printable_limit: 120), 300)
  end

  defp summary(term), do: clip(inspect(term, limit: 12, printable_limit: 120), 300)

  @doc false
  # Long or multi-line strings anywhere in a term: at most 6, looking at most 8 levels deep
  # and at no more than 500 values, so a huge or hostile term costs little.
  def texts(term) when is_binary(term) do
    if String.valid?(term), do: [{nil, clip(term, 4000)}], else: []
  end

  def texts(term), do: walk(term, [], {[], 500}) |> elem(0) |> Enum.reverse() |> Enum.take(6)

  defp walk(_term, path, {found, budget} = acc)
       when budget <= 0 or length(path) > 8 or length(found) >= 6,
       do: acc

  defp walk(term, path, {found, budget}) when is_binary(term) do
    if String.valid?(term) and (byte_size(term) >= 60 or String.contains?(term, "\n")),
      do: {[{Enum.join(path, " › "), clip(term, 4000)} | found], budget - 1},
      else: {found, budget - 1}
  end

  defp walk(term, path, {found, budget}) do
    for {label, child} <- children(term, budget), reduce: {found, budget - 1} do
      acc -> walk(child, path ++ [label], acc)
    end
  end

  # At most n children of a tuple, list (proper or not) or map, each with a label.
  defp children(t, n) when is_tuple(t),
    do: for(i <- 0..(min(tuple_size(t), n) - 1)//1, do: {"elem #{i}", elem(t, i)})

  defp children(l, n) when is_list(l), do: list_children(l, 0, n)
  defp children(m, n) when is_map(m), do: map_children(:maps.next(:maps.iterator(m)), n)
  defp children(_, _), do: []

  defp list_children([h | t], i, n) when i < n,
    do: [{"item #{i}", h} | list_children(t, i + 1, n)]

  defp list_children([], _, _), do: []
  defp list_children(tail, i, n) when not is_list(tail) and i < n, do: [{"tail", tail}]
  defp list_children(_, _, _), do: []

  defp map_children({k, v, next}, n) when n > 0,
    do: [{key(k), v} | map_children(:maps.next(next), n - 1)]

  defp map_children(_, _), do: []

  defp key(k) when is_atom(k), do: "#{k}:"
  defp key(k), do: inspect(k, limit: 3, printable_limit: 40) <> " =>"

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> " …", else: text
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

  @doc "Why `NanoAgent.start/1` refused, as text: the prompt file's error in words, anything else inspected."
  def refusal({:system_prompt_file, reason}) when is_atom(reason),
    do: "cannot read system_prompt_file: #{:file.format_error(reason)}"

  def refusal(reason), do: inspect(reason)

  @doc "The reasoning levels an agent can be started with, \"off\" first."
  def reasoning_levels, do: Enum.uniq(["off" | NanoAgent.reasoning_levels()])

  @doc "Why an agent is halted, in words (shared by the agent page and the overview)."
  def halt_reason(:budget), do: "its own turn or token budget is used up"

  def halt_reason(:context),
    do:
      "context limit reached: the conversation sent to the model is as large as it may get " <>
        "and never shrinks, so un-halting allows one more model call before it halts again"

  def halt_reason(:node_budget), do: "the node-wide hourly token cap was reached"
  def halt_reason(:restart_brake), do: "restart brake: it restarted 3 times within 60 s"

  def halt_reason(:start_failed),
    do: "its process failed while starting or restoring; un-halting retries the start"

  def halt_reason(:log_failed),
    do:
      "the harness could not write its log, so it stopped rather than act unlogged; fix the disk, then un-halt"

  def halt_reason(other), do: "reason #{inspect(other)}"

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

  @doc "A limit as `used / max`: a max of 0 means no limit (∞); a value the state lacks shows as –."
  def limit(used, max), do: "#{int(used)} / #{if max == 0, do: "∞", else: int(max)}"

  def cost(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 4)
  def cost(nil), do: "–"
  def cost(n), do: txt(n)

  def percent(rate) when is_number(rate), do: "#{round(rate * 100)}%"
  def percent(_), do: "–"
end
