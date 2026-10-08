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

  All APIs return `{:ok, value}` / `{:error, actionable_text}`. `stop/2` is the
  conversation brake; notification preferences bound interruptions. History is paged
  (latest 100 by default, `before:` message id); cuts are explicit. Attachments are
  inert downloads, not inline active content. Bot posts are limited to 32 KB.

  Isolation/testing: `start_link(root: unique_directory, runtime: module)` returns a
  store pid; pass `server: pid` to every API. See `Seedling.Bots.Runtime` for the
  adapter contract. Default storage lives next to the harness state directory.
  """
  alias Seedling.Bots.Store

  def start_link(opts), do: Store.start_link(opts)

  def server do
    root = Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "bots")
    name = {:global, {Store, root}}

    case GenServer.whereis(name) do
      nil ->
        case GenServer.start(Store, [root: root], name: name) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          {:error, reason} -> raise "Cannot open bots store: #{inspect(reason)}"
        end

      pid ->
        pid
    end
  end

  defp call(opts, request),
    do: GenServer.call(Keyword.get(opts, :server) || server(), request, 15_000)

  def snapshot(opts \\ []), do: call(opts, :snapshot)
  def create_bot(name, opts \\ []), do: call(opts, {:create_bot, name, opts})
  def configure(config, opts \\ []), do: call(opts, {:configure, config})
  def create_session(bots, opts \\ []), do: call(opts, {:create_session, bots, opts[:title]})
  def history(session, opts \\ []), do: call(opts, {:history, session, opts})

  def say(session, text, opts \\ []),
    do: call(opts, {:say, session, text, opts[:attachments] || []})

  def post(bot, session, text, opts \\ []),
    do: call(opts, {:post, bot, session, text, opts[:attachments] || []})

  def quiet(bot, session, opts \\ []), do: call(opts, {:quiet, bot, session})
  def status(bot, session, text, opts \\ []), do: call(opts, {:status, bot, session, text})
  def stop(session, opts \\ []), do: call(opts, {:stop, session})
  def remember(bot, text, opts \\ []), do: call(opts, {:remember, bot, text, opts})
  def memories(bot, query, opts \\ []), do: call(opts, {:memories, bot, query, opts})
  def forget(bot, id, opts \\ []), do: call(opts, {:forget, bot, id})
  def ask_human(bot, question, opts \\ []), do: call(opts, {:ask, bot, question, opts, self()})
  def answer(request, text, opts \\ []), do: call(opts, {:answer, request, text})
  def cancel_request(request, opts \\ []), do: call(opts, {:cancel, request})
  def ack(request, opts \\ []), do: call(opts, {:ack, request})

  def notification_limits(session, prefs, opts \\ []),
    do: call(opts, {:preferences, session, prefs})

  def attach(path, name, opts \\ []), do: call(opts, {:attach, path, name})
  def attachment(id, opts \\ []), do: call(opts, {:attachment, id})

  def subscribe(opts \\ []) do
    {:ok, %{topic: topic}} = call(opts, :topic)
    Phoenix.PubSub.subscribe(Nano.PubSub, topic)
  end
end
