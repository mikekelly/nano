defmodule Vega.Bots do
  @moduledoc """
  Durable consumer bots, isolated sessions and the human conduit. Start
  `{Vega.Bots.Server, root: "/data/vega"}` under supervision and visit `/bots`.
  All reads/mutations return `{:ok, value}` or `{:error, reason}`. Optional `server:`
  chooses an isolated service; state records use JSON string keys.

      {:ok, bot} = Vega.Bots.create_bot("Muse", model: "openai-codex/gpt-6.1-sol",
        reasoning: "low", max_context: 272000, max_turns: 0, max_tokens: 0)
      {:ok, chat} = Vega.Bots.create_session([bot["id"]])
      Vega.Bots.send_message(chat["id"], "Help me plan tomorrow")

  Agents MUST post through eval, not final prose:
  `Vega.Bots.post(session_id, bot_id, "**Hello**")`. Use `remember/3` for durable
  facts, not every utterance. `request_human/3` requires `requester: "stable-agent-name"`;
  answers arrive as `{:vega_human_answer, request_id, answer}`. Acknowledge with
  `acknowledge_answer/2` (requester: same name) after recording/handling the answer.
  Delivery retries by name survive process restarts; consumers must deduplicate IDs.
  """
  def start_link(opts \\ []), do: Vega.Bots.Server.start_link(opts)

  def snapshot(opts \\ []),
    do: Vega.Bots.Server.snapshot(Keyword.get(opts, :server, Vega.Bots.Server))

  def bots(opts \\ []), do: select("bots", opts)
  def sessions(opts \\ []), do: select("sessions", opts)

  def pending_requests(opts \\ []) do
    with {:ok, all} <- select("requests", opts),
         do: {:ok, Enum.filter(all, &(&1["status"] == "pending"))}
  end

  def get_bot(id, opts \\ []), do: get("bots", id, opts)

  def get_session(id, opts \\ []),
    do: Vega.Bots.Server.session(Keyword.get(opts, :server, Vega.Bots.Server), id, opts)

  def create_bot(name, opts \\ []), do: call({:create_bot, name, opts}, opts)
  def update_bot(id, attrs, opts \\ []), do: call({:update_bot, id, attrs}, opts)
  def create_session(ids, opts \\ []), do: call({:create_session, ids, opts}, opts)
  def update_session(id, attrs, opts \\ []), do: call({:update_session, id, attrs}, opts)
  def send_message(id, text, opts \\ []), do: call({:message, id, "person", text, opts}, opts)
  def post(session, bot, text, opts \\ []), do: call({:message, session, bot, text, opts}, opts)

  def status(session, bot, state, opts \\ []),
    do: call({:status, session, bot, state, opts}, opts)

  def request_human(bot, question, opts \\ []), do: call({:request, bot, question, opts}, opts)
  def answer_request(id, answer, opts \\ []), do: call({:answer, id, answer}, opts)
  def acknowledge_answer(id, opts \\ []), do: call({:ack, id, opts[:requester]}, opts)
  def update_settings(attrs, opts \\ []), do: call({:settings, attrs}, opts)
  def reload(opts \\ []), do: call(:reload, opts)
  def retry(session, opts \\ []), do: call({:retry, session}, opts)

  def remember(bot, content, opts \\ []) do
    with {:ok, _} <- get_bot(bot, opts),
         {:ok, root} <- call(:root, opts),
         do: Vega.Memory.put("bot:" <> bot, content, Keyword.put(opts, :root, root))
  end

  def retrieve(bot, query, opts \\ []) do
    with {:ok, _} <- get_bot(bot, opts),
         {:ok, root} <- call(:root, opts),
         do: Vega.Memory.retrieve("bot:" <> bot, query, Keyword.put(opts, :root, root))
  end

  def subscribe(opts \\ []) do
    with {:ok, topic} <- call(:topic, opts),
         :ok <- Phoenix.PubSub.subscribe(Nano.PubSub, topic),
         do: {:ok, topic}
  end

  def attach_file(path, opts \\ []) do
    with {:ok, root} <- call(:root, opts), do: Vega.Bots.Files.import(path, root)
  end

  def download_file(id, opts \\ []) do
    with {:ok, root} <- call(:root, opts), do: Vega.Bots.Files.fetch(id, root)
  end

  def agent_name(bot, session), do: "bot." <> bot <> "." <> session
  defp select(key, opts), do: with({:ok, s} <- snapshot(opts), do: {:ok, s[key]})

  defp get(key, id, opts) do
    with {:ok, xs} <- select(key, opts) do
      case Enum.find(xs, &(&1["id"] == id)) do
        nil -> {:error, :not_found}
        x -> {:ok, x}
      end
    end
  end

  defp call(msg, opts) do
    GenServer.call(Keyword.get(opts, :server, Vega.Bots.Server), msg, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :busy}
    :exit, reason -> {:error, {:service_unavailable, reason}}
  end
end
