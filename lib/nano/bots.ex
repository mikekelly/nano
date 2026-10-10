defmodule Nano.Bots do
  @moduledoc """
  Durable consumer domain, no model calls. Final opts accept `server: Nano.Bots.Store`.
  Mutations/get return `{:ok, record}`; lists `{:ok, list}`. Errors: `{:error, atom}`
  or `{:error, {:storage, reason}}`. Records are atom-keyed maps, random immutable
  string id and created_at milliseconds. Bots: name/face/color/description/voice.
  Sessions: participant_ids/title/epoch/stopped/exchange_count/exchange_ceiling/
  notification_prefs. Epoch starts 0, ceiling defaults 12. stop_session accepts expected_epoch: integer
  for atomic compare-and-stop (:stale_epoch mismatch, :invalid malformed). Omitting
  expected_epoch preserves unconditional stop. Human posts advance epoch,
  clear stopped and reset budget. Stop advances epoch. Bot publish requires current
  epoch, participant actor `{:bot, id}` and idempotency_key. Errors :stale_epoch,
  :stopped, :exchange_ceiling, :idempotency_conflict. Exact retries return original
  message even after epoch changes and do not emit events. Messages: session_id,
  sequence (1-based), actor (:human or {:bot, id}), text, attachments (string refs),
  epoch, idempotency_key. Every bot post counts toward ceiling.
  list_messages opts `after: 0, limit: 50` (1..200) returns
  `{:ok, %{messages: ascending_list, next_cursor: sequence, has_more: boolean}}`.
  With `tail: true`, returns latest limit messages ascending; `has_more` means older
  messages exist. Optional `before: sequence` (exclusive, tail mode only) pages
  older messages; use first displayed sequence for before. next_cursor is always
  last/newest displayed sequence for after/live polling (0 if empty tail page).
  tail cannot combine with explicit after. Default forward mode is unchanged.

  request_human takes bot_id/session_id/requester (stable name, not pid)/text.
  Requests: status :pending/:answered/:acked, answer, delivery_attempts.
  Requests are separate answerable items (list_requests and :request_created), not
  synthetic bot messages. Answer human message has request_id.
  Keys prefixed request-answer: or request-question: are internal; public posts
  using them return :reserved_key.
  answer_request atomically posts human answer and stores durable outbox answer.
  outbox lists answered unacked requests; mark_delivery increments attempts;
  ack_request persists acknowledgment. Runtime delivers by stable requester and
  deduplicates by request id; restart must reconcile outbox and list_sessions.
  Memory records: bot_id/text/provenance (map), human editable/deletable, bounded
  200 per bot (oldest evicted). list_memories newest first, limit 1..200.

  Store publishes `{:bots, event, record}` after disk commit to `"bots"` and
  `"bots:session:" <> record.session_id` when present (session lifecycle events
  use record.id). Events: :bot_created,
  :bot_updated, :bot_deleted, :session_created, :session_updated, :session_deleted,
  :session_stopped, :message_created, :request_created, :request_answered,
  :request_delivery, :request_acked, :memory_created, :memory_updated, :memory_deleted.
  Optional store `notify: {module, function}` calls function(event_tuple) only after
  persistence; failure cannot roll back. Runtime reconciles persisted state at boot.
  No pid persisted, no harness log scraping. Session updates only title/preferences/
  ceiling; bot deletion rejects referenced bots with :in_use.
  """
  alias Nano.Bots.Store
  defp call(op, args, opts), do: GenServer.call(Keyword.get(opts, :server, Store), {op, args})
  def create_bot(a, opts \\ []), do: call(:create_bot, [a], opts)
  def update_bot(a, b, opts \\ []), do: call(:update_bot, [a, b], opts)
  def delete_bot(a, opts \\ []), do: call(:delete_bot, [a], opts)
  def get_bot(a, opts \\ []), do: call(:get_bot, [a], opts)
  def list_bots(opts \\ []), do: call(:list_bots, [], opts)
  def create_session(a, opts \\ []), do: call(:create_session, [a], opts)
  def update_session(a, b, opts \\ []), do: call(:update_session, [a, b], opts)
  def delete_session(a, opts \\ []), do: call(:delete_session, [a], opts)
  def get_session(a, opts \\ []), do: call(:get_session, [a], opts)
  def list_sessions(opts \\ []), do: call(:list_sessions, [], opts)

  def stop_session(a, opts \\ []),
    do: call(:stop_session, [a, Keyword.fetch(opts, :expected_epoch)], opts)

  def post_human(a, b, opts \\ []), do: call(:post_human, [a, b], opts)
  def publish(a, b, opts \\ []), do: call(:publish, [a, b], opts)
  def request_human(a, opts \\ []), do: call(:request_human, [a], opts)
  def get_request(a, opts \\ []), do: call(:get_request, [a], opts)
  def answer_request(a, b, opts \\ []), do: call(:answer_request, [a, b], opts)
  def mark_delivery(a, opts \\ []), do: call(:mark_delivery, [a], opts)
  def ack_request(a, opts \\ []), do: call(:ack_request, [a], opts)
  def outbox(opts \\ []), do: call(:outbox, [], opts)
  def list_requests(opts \\ []), do: call(:list_requests, [], opts)
  def create_memory(a, b, opts \\ []), do: call(:create_memory, [a, b], opts)
  def update_memory(a, b, opts \\ []), do: call(:update_memory, [a, b], opts)
  def delete_memory(a, opts \\ []), do: call(:delete_memory, [a], opts)
  def list_messages(id, opts \\ []), do: call(:list_messages, [id, opts], opts)
  def list_memories(id, opts \\ []), do: call(:list_memories, [id, opts], opts)
end
