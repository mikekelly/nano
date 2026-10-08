defmodule Seedling.Bots do
  @moduledoc """
  Durable bot identities, isolated chat sessions and a human-request conduit.

  A bot/session pair has one stable named agent: separate contexts prevent accidental
  transcript leakage; only selectively retrieved memories cross session boundaries.
  Agents are started lazily, restored by the harness and automatically compacted by
  its compaction integration. Configure a model before chatting: no provider is chosen
  implicitly. The `/bots` surface never exposes evals or harness traffic.

      {:ok, bot} = Seedling.Bots.create_bot("Muse", description: "A thoughtful helper")
      {:ok, session} = Seedling.Bots.create_session([bot["id"]])
      Seedling.Bots.say(session["id"], "Help plan a trip")
      # Inside that session's agent (the sender pid is checked):
      Seedling.Bots.post(bot["id"], session["id"], "Where would you like to go?")
      Seedling.Bots.remember(bot["id"], "Prefers quiet hotels", tags: ["travel"])
      Seedling.Bots.quiet(bot["id"], session["id"])

  Human requests can be made by any node agent, with durable named delivery:

      {:ok, request} = Seedling.Bots.ask_human(bot_id, "Choose a region",
        reply_to: {:agent, "planner"}, correlation: "region")
      # Human uses the answer button in /bots, or:
      Seedling.Bots.answer(request["id"], "Europe")
      # planner receives {:bots_human_answer, request_id, "region", "Europe"}

  Requests are durable, expiring, explicitly answerable, and answers are delivered
  at least once (acknowledge with `ack/1`). A pid reply target is supported but cannot
  survive a node restart. Never request credentials in chat; ask the person to set
  the named credential in operator settings and reply that it is ready instead.

  Queries and mutations return `{:ok, value}` / `{:error, actionable_text}`;
  `subscribe/1` returns `:ok`, and `server/1` returns a pid or an error. `stop/2` is the
  conversation brake; notification preferences bound interruptions. History is paged
  (latest 100 by default, `before:` message id); cuts are explicit. Snapshot shows
  the latest 200 sessions (`limit:` up to 1000, `session:` ensures the open chat is
  included) and the latest 200 requests; counts and cut notices are returned. Attachments are
  inert downloads, not inline active content. Bot posts are limited to 32 KB.

  Isolation/testing: `start_link(root: unique_directory, runtime: module)` returns a
  store pid; pass `server: pid` or `root: directory` to every API. See `Seedling.Bots.Runtime` for the
  adapter contract. Default storage lives next to the harness state directory.
  """
  alias Seedling.Bots.Store

  def start_link(opts) do
    if Keyword.keyword?(opts) and is_binary(opts[:root]),
      do: open_link(opts),
      else: {:error, "Give root: a unique directory path."}
  rescue
    _ -> {:error, "Give root: a unique directory path."}
  end

  defp open_link(opts) do
    case Store.start_link(opts) do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        {:error,
         "Cannot open bots store; check root permissions and store.json or restore a valid backup."}
    end
  end

  def default_root, do: Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "bots")

  @doc "Resolve a store pid (or an actionable error); never replaces corrupt persisted identities."
  def server(root \\ default_root())

  def server(root) when is_binary(root) do
    root = Path.expand(root)
    name = {:global, {Store, root}}

    case GenServer.whereis(name) do
      nil ->
        case GenServer.start(Store, [root: root], name: name) do
          {:ok, pid} ->
            pid

          {:error, {:already_started, pid}} ->
            pid

          {:error, _} ->
            {:error,
             "Cannot open bots at #{root}. Check permissions and store.json; restore a valid backup rather than deleting identity state."}
        end

      pid ->
        pid
    end
  rescue
    _ -> {:error, "Cannot open bots store. Check root and permissions."}
  catch
    :exit, _ -> {:error, "Bots store unavailable; retry or restore a valid backup."}
  end

  def server(_), do: {:error, "Store root must be a directory path."}

  defp dispatch(opts, request) do
    if is_list(opts) and Keyword.keyword?(opts) do
      term = request.()

      with :ok <- validate(term),
           pid when is_pid(pid) <- opts[:server] || server(opts[:root] || default_root()) do
        GenServer.call(pid, term, 15_000)
      else
        {:error, _} = error -> error
        _ -> {:error, "The server option must be a bots store pid."}
      end
    else
      {:error, "Options must be a keyword list (server: pid or root: directory)."}
    end
  rescue
    _ -> {:error, "Invalid arguments. Use the documented field types and bounded text values."}
  catch
    :exit, _ ->
      {:error, "Bots store unavailable or timed out; retry. Do not delete identity state."}
  end

  def snapshot(opts \\ []), do: dispatch(opts, fn -> {:snapshot, opts} end)
  def create_bot(name, opts \\ []), do: dispatch(opts, fn -> {:create_bot, name, opts} end)
  def configure(config, opts \\ []), do: dispatch(opts, fn -> {:configure, config} end)

  def create_session(bots, opts \\ []),
    do: dispatch(opts, fn -> {:create_session, bots, opts[:title]} end)

  def history(session, opts \\ []), do: dispatch(opts, fn -> {:history, session, opts} end)

  def say(session, text, opts \\ []),
    do: dispatch(opts, fn -> {:say, session, text, opts[:attachments] || []} end)

  def post(bot, session, text, opts \\ []),
    do: dispatch(opts, fn -> {:post, bot, session, text, opts[:attachments] || []} end)

  def quiet(bot, session, opts \\ []), do: dispatch(opts, fn -> {:quiet, bot, session} end)

  def status(bot, session, text, opts \\ []),
    do: dispatch(opts, fn -> {:status, bot, session, text} end)

  def stop(session, opts \\ []), do: dispatch(opts, fn -> {:stop, session} end)
  def remember(bot, text, opts \\ []), do: dispatch(opts, fn -> {:remember, bot, text, opts} end)

  def memories(bot, query, opts \\ []),
    do: dispatch(opts, fn -> {:memories, bot, query, opts} end)

  def forget(bot, id, opts \\ []), do: dispatch(opts, fn -> {:forget, bot, id} end)

  def ask_human(bot, question, opts \\ []),
    do: dispatch(opts, fn -> {:ask, bot, question, opts, self()} end)

  def answer(request, text, opts \\ []), do: dispatch(opts, fn -> {:answer, request, text} end)
  def cancel_request(request, opts \\ []), do: dispatch(opts, fn -> {:cancel, request} end)
  def ack(request, opts \\ []), do: dispatch(opts, fn -> {:ack, request} end)

  def notification_limits(session, prefs, opts \\ []),
    do: dispatch(opts, fn -> {:preferences, session, prefs} end)

  def attach(path, name, opts \\ []), do: dispatch(opts, fn -> {:attach, path, name} end)
  def attachment(id, opts \\ []), do: dispatch(opts, fn -> {:attachment, id} end)

  def subscribe(opts \\ []) do
    with {:ok, %{topic: topic}} <- dispatch(opts, fn -> :topic end),
         do: Phoenix.PubSub.subscribe(Nano.PubSub, topic)
  catch
    :exit, _ -> {:error, "Live updates unavailable; refresh to retry."}
  end

  defp validate(term) do
    if valid?(term),
      do: :ok,
      else:
        {:error,
         "Invalid arguments. Check ids, bounded text, numeric limits and keyword options in Seedling.Bots docs."}
  end

  defp valid?(:topic), do: true

  defp valid?({:snapshot, o}),
    do: optional_number?(o[:limit], 1, 1000) and optional_string?(o[:session])

  defp valid?({:create_bot, name, o}),
    do: string?(name) and optional_string?(o[:description]) and optional_string?(o[:voice])

  defp valid?({:configure, c}),
    do: is_map(c) and Enum.all?(Map.keys(c), &(is_binary(&1) or is_atom(&1)))

  defp valid?({:create_session, ids, title}), do: strings?(ids) and optional_string?(title)

  defp valid?({:history, id, o}),
    do: string?(id) and optional_string?(o[:before]) and optional_number?(o[:limit], 1, 500)

  defp valid?({:say, id, text, refs}), do: string?(id) and string?(text) and strings?(refs)

  defp valid?({:post, bot, id, text, refs}),
    do: string?(bot) and string?(id) and string?(text) and strings?(refs)

  defp valid?({:quiet, bot, id}), do: string?(bot) and string?(id)
  defp valid?({:status, bot, id, text}), do: string?(bot) and string?(id) and string?(text)

  defp valid?({:remember, bot, text, o}),
    do:
      string?(bot) and string?(text) and strings?(o[:tags] || []) and
        optional_string?(o[:session])

  defp valid?({:memories, bot, text, o}),
    do: string?(bot) and string?(text) and optional_number?(o[:limit], 1, 10)

  defp valid?({:forget, bot, id}), do: string?(bot) and string?(id)

  defp valid?({:ask, bot, text, o, _}),
    do:
      string?(bot) and string?(text) and target?(o[:reply_to]) and optional_string?(o[:session]) and
        optional_string?(o[:correlation]) and optional_number?(o[:expires_in], 1, 604_800)

  defp valid?({:answer, id, text}), do: string?(id) and string?(text)

  defp valid?({:preferences, id, prefs}),
    do:
      string?(id) and is_map(prefs) and
        Enum.all?(Map.keys(prefs), &(is_binary(&1) or is_atom(&1)))

  defp valid?({:attach, path, name}), do: string?(path) and string?(name)
  defp valid?({kind, id}) when kind in [:stop, :cancel, :ack, :attachment], do: string?(id)
  defp valid?(_), do: false
  defp string?(value), do: is_binary(value) and String.valid?(value)
  defp optional_string?(nil), do: true
  defp optional_string?(value), do: string?(value)
  defp strings?(value), do: is_list(value) and Enum.all?(value, &string?/1)
  defp optional_number?(nil, _, _), do: true
  defp optional_number?(value, min, max), do: is_integer(value) and value >= min and value <= max
  defp target?(nil), do: true
  defp target?(pid) when is_pid(pid), do: true

  defp target?({:agent, name}),
    do: is_binary(name) and Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,180}\z/, name)

  defp target?(_), do: false
end
