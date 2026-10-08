defmodule Bots do
  @moduledoc """
  Persistent consumer conversations, separate from the operator harness timeline.

      {:ok, bot} = Bots.create_bot(%{name: "Mira", description: "Thoughtful researcher"})
      {:ok, chat} = Bots.create_session([bot["id"]])
      Bots.say(chat["id"], "Help me plan tomorrow")

  Mutations return `{:ok, string_keyed_map}` or `{:error, reason}`. Reads return
  maps; `session/2` returns nil when missing. Every call takes `server: pid_or_name`
  for isolated instances. Start one with `start_link(root: path, name: nil,
  runtime: MyRuntime)`. Production defaults to `Bots.Runtime`; no test calls a model.

  Runtime replies use a granted response token: `post/3` and `finish/2`. Genuine
  background completions can use `announce/4` (also `post/4`), which verifies the
  owning bot/session agent and enforces the same discussion ceiling. Proactive posts
  cannot preempt a pending human turn. Harness responses and eval output are never copied into chat. New human
  messages and stop revoke old grants. The complete durable transcript is provided at
  each wake, including messages a bot silently observed while another spoke.

  Other agents ask humans with `request(bot_id, text, requester: "agent-name")`.
  They receive `{:bots_answer, request_id, text}` and must deduplicate on request_id
  then `ack/2`. Answer transitions are exactly once; outbox transport is deliberately
  at-least-once across crashes. `request_status/2` also permits durable polling.
  A PID requester is supported within this VM only; prefer stable NanoAgent names.
  `idempotency_key:` prevents duplicate requests from a retrying producer.

  `subscribe/1` publishes `{:bots_changed, session_id_or_nil}` and budgeted
  `{:bots_notification, %{title: ..., body: ..., session_id: ..., id: ...}}` on
  Nano.PubSub. Notifications default off. All text and attachments are untrusted.
  """

  def start_link(opts \\ []), do: Bots.Server.start_link(opts)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  def snapshot(opts \\ []), do: call(:snapshot, opts)
  def session(id, opts \\ []), do: call({:session, id}, opts)
  def create_bot(attrs, opts \\ []), do: call({:create_bot, attrs}, opts)
  def create_session(ids, opts \\ []), do: call({:create_session, ids, opts}, opts)
  def say(id, text, opts \\ []), do: call({:say, id, text, opts}, opts)
  def stop(id, opts \\ []), do: call({:stop, id}, opts)
  def preferences(attrs, opts \\ []), do: call({:preferences, attrs}, opts)

  def post(token, text, opts \\ []),
    do: call({:post, token, text, Keyword.put(opts, :actor, actor())}, opts)

  @doc "Post a genuine proactive update from the owning bot/session agent. Subject to stop and exchange ceilings."
  def announce(bot_id, session_id, text, opts \\ []),
    do: call({:announce, bot_id, session_id, text, Keyword.put(opts, :actor, actor())}, opts)

  def post(bot_id, session_id, text, opts), do: announce(bot_id, session_id, text, opts)

  def remember(token, key, value, opts \\ []),
    do: call({:remember, token, key, value, actor()}, opts)

  def finish(token, opts \\ []), do: call({:finish, token, actor()}, opts)

  def request(bot_id, text, opts \\ []) do
    requester = Keyword.get_lazy(opts, :requester, &caller/0)
    call({:request, bot_id, text, Keyword.put(opts, :requester, requester)}, opts)
  end

  def reply(id, text, opts \\ []), do: call({:reply, id, text}, opts)
  def ack(id, opts \\ []), do: call({:ack, id}, opts)
  def request_status(id, opts \\ []), do: call({:request_status, id}, opts)

  def subscribe(opts \\ []) do
    topic = call(:topic, opts)
    Phoenix.PubSub.subscribe(Keyword.get(opts, :pubsub, Nano.PubSub), topic)
  end

  defp actor, do: List.first(Process.get(:"$callers", [])) || self()

  defp caller do
    pid = actor()
    Enum.find(NanoAgent.list(), &(NanoAgent.whereis(&1) == pid)) || pid
  end

  defp call(message, opts) do
    server = Keyword.get(opts, :server, Bots.Server)

    if server == Bots.Server and Process.whereis(Bots.Server) == nil do
      if Process.whereis(Nano.OptionalServices) do
        raise "Bots service unavailable: waiting for supervised recovery"
      end

      case GenServer.start(Bots.Server, [], name: Bots.Server) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> raise "Bots service unavailable: #{inspect(reason)}"
      end
    end

    GenServer.call(server, message, 15_000)
  end
end
