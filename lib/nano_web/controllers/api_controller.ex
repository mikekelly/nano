defmodule NanoWeb.ApiController do
  @moduledoc """
  The JSON API: a thin skin over `Nano.Ops` and `Nano.User`, so it can do exactly what the
  dashboard and the shell can. Pids go out as strings like `"#PID<0.231.0>"`, terms come in
  as Elixir source and go out as `inspect/2` output, and errors are `{"error": ...}`.
  """
  use Phoenix.Controller, formats: [:json]

  alias Nano.{Ops, User}

  @keepalive_ms 15_000

  @endpoints [
    {"GET", "/api", "This index."},
    {"POST", "/api/images",
     "Upload an image: JSON base64, at most 5,000,000 encoded bytes; validated type, size and dimensions. Returns immutable image_ref metadata, never base64."},
    {"GET", "/api/images/:hash",
     "Immutable image bytes by lowercase SHA-256 hash. Invalid or missing hashes give 404."},
    {"GET", "/api/processes",
     "Live processes outside the standard set (boot-time, OTP and dashboard processes), agents first. " <>
       "Each: pid, name, kind (agent | user | spawned_by | other), spawned_by (agent name), " <>
       "current_function, message_queue_len, memory, reductions, agent (info, for agents). " <>
       "kind other = appeared since boot, belongs to no agent: usually the interesting ones."},
    {"GET", "/api/processes/:target",
     "Process.info for one process, plus kind. :target is a URL-encoded pid string, an agent, user or registered name."},
    {"GET", "/api/agents",
     "All agents: status (idle, thinking, running_tool, or waiting_retry: a model call failed " <>
       "and it calls again at retry_at), halted, suspended, model, reasoning, budget used, " <>
       "cost, restart count."},
    {"POST", "/api/agents",
     "Start an agent. Nothing has a default; required: name; model (a slug its provider " <>
       "lists: openai-codex/<model> runs on the ChatGPT subscription connected with " <>
       "/api/chatgpt/login, anything else on OpenRouter if the node has its key (setting " <>
       "openrouter_api_key); " <>
       "providers in this index says which can be used now); reasoning (how hard the model thinks " <>
       "before answering: one of the model's levels, from {reasoning_levels}); max_turns (model " <>
       "calls) and max_tokens (prompt + completion tokens, summed), each a non-negative integer " <>
       "where 0 means no limit; max_context (tokens in the conversation sent to the model, from " <>
       "1 to the model's context window: no request is made that could pass it, reply " <>
       "included). Optional: start_idle (default true); system_prompt (a template string) or " <>
       "system_prompt_file (a template file, relative to the app directory; system_prompt wins " <>
       "if both are given; default template: the system_prompt_file setting, " <>
       "prompts/seed.txt unless changed). " <>
       "A refusal (422) says what was missing or wrong."},
    {"GET", "/api/agents/:name",
     "One agent: status, system prompt, budget (turns, tokens and context: used and max, " <>
       "0 = no limit), restart count."},
    {"POST", "/api/agents/:name/stop", "Terminate the agent and delete its state."},
    {"POST", "/api/agents/:name/restart",
     "Kill the agent with reason :operator_restart; it restarts with its history."},
    {"POST", "/api/agents/:name/resume", "Resume an agent suspended with :sys.suspend/1."},
    {"POST", "/api/agents/:name/unhalt",
     "Clear a halt. halted is budget (the agent's turns or tokens), context (its next request, " <>
       "with room for the reply, might not fit in max_context, or a response passed it; the " <>
       "conversation never shrinks, so it halts again before the next model call), node_budget (the node-wide " <>
       "hourly token cap), usage_limit (the provider refused with a usage limit, e.g. the " <>
       "ChatGPT subscription's; un-halt once it has reset), provider_unavailable (its model's " <>
       "provider was turned off, OpenRouter's key removed, or refused its credentials; fix " <>
       "that, then un-halt), model_refused (the provider refused its request as invalid; " <>
       "un-halting sends it again), " <>
       "restart_brake (3 restarts within 60 s), start_failed (its process " <>
       "failed while starting; un-halting retries the start) or log_failed (its log could not " <>
       "be written; fix the disk first)."},
    {"GET", "/api/agents/:name/log?since=:seq",
     "Log entries with seq > since (default 0), oldest first."},
    {"GET", "/api/agents/:name/stream?since=:seq",
     "Log entries with seq > since, then new ones live, as server-sent events (id: seq, data: entry JSON). " <>
       "Honours Last-Event-ID."},
    {"GET", "/api/raw/*path",
     "One file of the raw_model_log setting's record, as plain text: the exact bytes of a " <>
       "model request or response (a first line, the headers with credentials redacted, a " <>
       "blank line, the body). path is as the raw field of an agent's model_request, " <>
       "model_response and model_error log entries names it: <agent id>/<request id>-" <>
       "<attempt>.request.txt or .response.txt."},
    {"GET", "/api/users",
     "Running users: name, pid, messages (kept: the last 500 sent and received) and unread " <>
       "(received in conversations not read on the dashboard since). Users and their messages " <>
       "survive a node restart; their pids do not, so look a user up by name each time you " <>
       "send to it (Nano.User.pid(name))."},
    {"POST", "/api/users", "Start a user, or find it if already started. Body: name."},
    {"POST", "/api/users/:name/say",
     "The user sends %{sender_pid: user_pid, message: text} to a target. Body: to, text, optional images (list of stored image reference maps from POST /api/images)."},
    {"POST", "/api/users/:name/send_raw",
     "The user sends a term to a target exactly as given. Body: to, term (Elixir source, parsed and evaluated)."},
    {"GET", "/api/users/:name/inbox?clear=true",
     "Messages the user has received, oldest first: at, term."},
    {"GET", "/api/users/:name/threads",
     "The user's conversations, one per agent, most recently active first: agent (* for " <>
       "messages that name no agent), messages, unread, last_at, last (the latest, inspected). " <>
       "A message sent belongs to the agent it went to; one received, to the agent a pid in it " <>
       "belongs to, else to the one agent running an eval when it arrived (Erlang messages " <>
       "carry no sender)."},
    {"GET", "/api/users/:name/threads/:agent",
     "One conversation, both directions, oldest first: at, dir (sent or received), term " <>
       "(inspected). :agent is an agent name, or * for messages that name no agent."},
    {"POST", "/api/eval",
     "Evaluate Elixir on the node, like bin/rpc. Body: code. Returns result (inspected) and output (printed IO)."},
    {"GET", "/api/chatgpt",
     "The ChatGPT subscription agents on openai-codex/<model> run on: status (disconnected, " <>
       "pending, connected); while pending, user_code, verification_url and expires_at; once " <>
       "connected, email, plan and expires_at (of the access token, refreshed before then); " <>
       "error, the last failure. Tokens are never shown."},
    {"POST", "/api/chatgpt/login",
     "Start a device-code login and return the status, pending: a person opens verification_url " <>
       "in their own browser, signs in to ChatGPT and enters user_code; poll GET /api/chatgpt " <>
       "until status is connected. 502 if no code could be had."},
    {"POST", "/api/chatgpt/logout",
     "Forget the subscription's tokens, or cancel a pending login."},
    {"GET", "/api/settings",
     "The node's settings, changed while it runs: the node's own, then any the operators " <>
       "supplied under names of their own (such as SOME_SERVICE_KEY). Each: key, value, set " <>
       "(false: its default), default, applies (live, or agent_start: the system prompt " <>
       "states it, so agents keep the value they started with) and about. A secret (an API " <>
       "key, or any value of the operators' own) shows only set and last4, never its value."},
    {"PUT", "/api/settings/:key",
     "Set a setting, saved at once. Body: value. :key is one of the node's settings (in " <>
       "either case: OPENROUTER_API_KEY is openrouter_api_key), or any other name of letters, " <>
       "digits and _ for a value of the operators' own (any string, kept as a secret). " <>
       "Returns the setting; 422 says what is allowed."},
    {"DELETE", "/api/settings/:key",
     "Put one of the node's settings back to its default (a key: unset), or forget a value " <>
       "of the operators' own. Removing openrouter_api_key turns OpenRouter off: agents on it " <>
       "halt (provider_unavailable). Returns the setting."}
  ]

  @conventions "Pids are strings such as \"#PID<0.231.0>\". Wherever a target is expected (to), " <>
                 "give an agent name, a user name, a registered process name, or a pid string. " <>
                 "Terms are sent as Elixir source strings and returned as inspect/2 output. " <>
                 "Request bodies are JSON. Errors are JSON with an error field and, for parse or " <>
                 "eval failures, the exception in message. Unknown agents, users and processes give 404."

  def index(conn, _params) do
    levels = Enum.map_join(NanoWeb.Components.reasoning_levels(), ", ", &inspect/1)

    json(conn, %{
      description:
        "Nano Agent: one BEAM node hosting LLM agents, each a GenServer. " <>
          "Everything the dashboard can do is here too.",
      conventions: @conventions,
      # OpenRouter: whether the node has its key. ChatGPT: the subscription's status.
      providers: %{openrouter: Nano.Model.openrouter?(), chatgpt: Ops.chatgpt().status},
      endpoints:
        for {method, path, about} <- @endpoints do
          about = String.replace(about, "{reasoning_levels}", levels)
          %{method: method, path: path, description: about}
        end
    })
  end

  ## Processes

  def processes(conn, _params), do: json(conn, Enum.map(Ops.processes(), &process_json/1))

  def process(conn, %{"pid" => target}) do
    case Ops.process(target) do
      nil -> error(conn, 404, "no such process: #{target}")
      info -> json(conn, process_json(info))
    end
  end

  defp process_json(process) do
    {kind, spawned_by} =
      case process.kind do
        {:spawned_by, agent} -> {"spawned_by", agent}
        kind -> {kind, nil}
      end

    process
    |> Map.merge(%{kind: kind, spawned_by: spawned_by})
    |> Map.new(fn
      {key, name} when key in [:name, :registered_name] and is_atom(name) and name != nil ->
        {key, inspect(name)}

      {key, value} ->
        {key, encode(value)}
    end)
  end

  ## Agents

  def agents(conn, _params), do: json(conn, encode(Ops.agents()))

  def start_agent(conn, params) do
    opts =
      for {key, value} <-
            Map.take(
              params,
              ~w(model start_idle system_prompt system_prompt_file max_turns max_tokens max_context reasoning)
            ),
          do: {String.to_atom(key), value}

    with {:ok, [name]} <- strings(params, ["name"]) do
      case Ops.start_agent(name, opts) do
        {:ok, pid} ->
          conn |> put_status(201) |> json(encode(Ops.agent(name) || %{name: name, pid: pid}))

        {:error, {:already_started, _}} ->
          error(conn, 409, "agent already started: #{name}")

        {:error, message} ->
          error(conn, 422, "could not start agent: #{message}")
      end
    else
      {:error, field} -> missing(conn, field)
    end
  end

  def agent(conn, %{"name" => name}) do
    case Ops.agent(name) do
      nil -> error(conn, 404, "no such agent: #{name}")
      info -> json(conn, encode(info))
    end
  end

  def stop_agent(conn, %{"name" => name}), do: lifecycle(conn, name, Ops.stop_agent(name))
  def restart_agent(conn, %{"name" => name}), do: lifecycle(conn, name, Ops.restart_agent(name))
  def resume(conn, %{"name" => name}), do: lifecycle(conn, name, Ops.resume(name))
  def unhalt(conn, %{"name" => name}), do: lifecycle(conn, name, Ops.unhalt(name))

  defp lifecycle(conn, _name, :ok), do: json(conn, %{ok: true})
  defp lifecycle(conn, name, {:error, :not_found}), do: error(conn, 404, "no such agent: #{name}")
  defp lifecycle(conn, _name, {:error, reason}), do: error(conn, 500, inspect(reason))

  def log(conn, %{"name" => name} = params) do
    with {:ok, since} <- since(params["since"]),
         entries when is_list(entries) <- Ops.log(name, since) do
      json(conn, entries)
    else
      :bad_since -> error(conn, 400, "since must be a non-negative integer")
      {:error, :not_found} -> error(conn, 404, "no such agent: #{name}")
    end
  end

  def stream(conn, %{"name" => name} = params) do
    with {:ok, since} <-
           since(List.first(get_req_header(conn, "last-event-id")) || params["since"]),
         %{id: id} <- Ops.agent(name) do
      # Subscribe before reading the backlog, so nothing falls between the two.
      Nano.Log.subscribe(id)

      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
      |> sse(Nano.Log.read(id, since), since)
    else
      :bad_since -> error(conn, 400, "since must be a non-negative integer")
      nil -> error(conn, 404, "no such agent: #{name}")
    end
  end

  # Sends the backlog, then each live entry as it arrives, until a write fails: that is how a
  # closed connection shows up, so a keepalive comment is written when nothing else is.
  defp sse(conn, [entry | rest], last) do
    seq = entry[:seq] || entry["seq"]

    if seq <= last,
      do: sse(conn, rest, last),
      else: write(conn, "id: #{seq}\ndata: #{Jason.encode!(entry)}\n\n", rest, seq)
  end

  defp sse(conn, [], last) do
    receive do
      {:nano_log, entry} -> sse(conn, [entry], last)
    after
      @keepalive_ms -> write(conn, ": keepalive\n\n", [], last)
    end
  end

  defp write(conn, data, rest, last) do
    case chunk(conn, data) do
      {:ok, conn} -> sse(conn, rest, last)
      {:error, _closed} -> conn
    end
  end

  ## Users

  def start_user(conn, params) do
    case strings(params, ["name"]) do
      {:ok, [name]} -> json(conn, %{name: name, pid: inspect(User.start(name))})
      {:error, field} -> missing(conn, field)
    end
  end

  def say(conn, %{"name" => name} = params) do
    case strings(params, ["to", "text"]) do
      {:ok, [to, text]} ->
        payload =
          if Map.has_key?(params, "images"),
            do: %{text: text, images: params["images"]},
            else: text

        sent(conn, name, to, User.say(name, to, payload))

      {:error, field} ->
        missing(conn, field)
    end
  end

  def send_raw(conn, %{"name" => name} = params) do
    with {:ok, [to, source]} <- strings(params, ["to", "term"]),
         pid when is_pid(pid) <- User.pid(name),
         {:ok, term} <- Ops.term(source) do
      sent(conn, name, to, User.send_raw(name, to, term))
    else
      {:error, "term"} -> missing(conn, "term")
      {:error, "to"} -> missing(conn, "to")
      nil -> error(conn, 404, "no such user: #{name}")
      {:error, message} -> error(conn, 422, "could not evaluate term", message)
    end
  end

  defp sent(conn, _name, _to, :ok), do: json(conn, %{ok: true})

  defp sent(conn, name, _to, {:error, :unknown_user}),
    do: error(conn, 404, "no such user: #{name}")

  defp sent(conn, name, _to, {:error, :unresponsive}), do: unresponsive(conn, name)

  defp sent(conn, _name, to, {:error, :unknown_target}),
    do: error(conn, 404, "no such target: #{to}")

  defp sent(conn, _name, _to, {:error, reason}), do: error(conn, 422, inspect(reason))

  defp unresponsive(conn, name),
    do:
      error(
        conn,
        503,
        "user #{name} is not responding (suspended or flooded?); the request is queued in its " <>
          "mailbox and will be carried out if it resumes, so retrying would repeat it"
      )

  def inbox(conn, %{"name" => name} = params) do
    case User.inbox(name, clear: params["clear"] == "true") do
      {:error, :unknown_user} ->
        error(conn, 404, "no such user: #{name}")

      {:error, :unresponsive} ->
        unresponsive(conn, name)

      messages ->
        json(conn, for(m <- messages, do: %{at: DateTime.to_iso8601(m.at), term: show(m.term)}))
    end
  end

  def users(conn, _params),
    do: json(conn, for(u <- User.counts(), do: %{u | pid: inspect(u.pid)}))

  def threads(conn, %{"name" => name}) do
    case User.threads(name) do
      {:error, :unknown_user} ->
        error(conn, 404, "no such user: #{name}")

      threads ->
        json(
          conn,
          for %{messages: messages} = t <- threads do
            last = List.last(messages)

            %{
              agent: t.agent || "*",
              messages: length(messages),
              unread: t.unread,
              last_at: DateTime.to_iso8601(last.at),
              last: show(last.term)
            }
          end
        )
    end
  end

  def thread(conn, %{"name" => name, "agent" => agent}) do
    agent = if agent == "*", do: nil, else: agent

    case User.threads(name) do
      {:error, :unknown_user} ->
        error(conn, 404, "no such user: #{name}")

      threads ->
        messages = Enum.find_value(threads, [], &(&1.agent == agent && &1.messages))

        json(
          conn,
          for(m <- messages, do: %{at: DateTime.to_iso8601(m.at), dir: m.dir, term: show(m.term)})
        )
    end
  end

  ## Eval

  def eval(conn, params) do
    with {:ok, [code]} <- strings(params, ["code"]) do
      case Ops.eval(code) do
        {:ok, result, output} ->
          json(conn, %{result: result, output: output})

        {:error, message, output} ->
          conn
          |> put_status(422)
          |> json(%{error: "eval failed", message: message, output: output})
      end
    else
      {:error, field} -> missing(conn, field)
    end
  end

  ## ChatGPT subscription

  def chatgpt(conn, _params), do: json(conn, encode(Ops.chatgpt()))

  def chatgpt_login(conn, _params) do
    case Ops.chatgpt_login() do
      {:error, message} -> error(conn, 502, "could not start a ChatGPT login", message)
      status -> json(conn, encode(status))
    end
  end

  def chatgpt_logout(conn, _params) do
    :ok = Ops.chatgpt_logout()
    json(conn, %{ok: true})
  end

  ## Raw model requests and responses

  # As text that a browser shows and never runs: a response body may hold anything.
  def raw(conn, %{"path" => parts}) do
    case Nano.RawLog.file(Enum.join(parts, "/")) do
      {:ok, path} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox")
        |> send_file(200, path)

      :error ->
        error(conn, 404, "no such raw_model_log file: #{Enum.join(parts, "/")}")
    end
  end

  ## Settings

  def settings(conn, _params), do: json(conn, encode(Ops.settings()))

  def put_setting(conn, %{"key" => key} = params) do
    if Map.has_key?(params, "value"),
      do: setting(conn, key, Ops.put_setting(key, params["value"])),
      else: error(conn, 422, "value is required")
  end

  def delete_setting(conn, %{"key" => key}), do: setting(conn, key, Ops.delete_setting(key))

  # The setting as GET /api/settings shows it; OPENROUTER_API_KEY is openrouter_api_key.
  defp setting(conn, key, :ok) do
    {:ok, key} = Nano.Settings.key(key)
    entry = Enum.find(Ops.settings(), &(&1.key == key))
    json(conn, encode(entry || %{key: key, set: false}))
  end

  defp setting(conn, key, {:error, message}) do
    missing? = match?({:error, _}, Nano.Settings.key(key)) or message =~ ~r/^no setting/
    error(conn, if(missing?, do: 404, else: 422), message)
  end

  ## Helpers

  defp since(nil), do: {:ok, 0}

  defp since(string) do
    case Integer.parse(string) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :bad_since
    end
  end

  # The values of the given body fields, all of which must be non-empty strings.
  defp strings(params, fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case params[field] do
        value when is_binary(value) and value != "" -> {:cont, {:ok, acc ++ [value]}}
        _ -> {:halt, {:error, field}}
      end
    end)
  end

  defp missing(conn, field), do: error(conn, 422, "#{field} is required (a non-empty string)")

  defp error(conn, status, error, message \\ nil) do
    body = if message, do: %{error: error, message: message}, else: %{error: error}
    conn |> put_status(status) |> json(body)
  end

  defp show(term), do: inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity)

  # Agent info and process maps as JSON: atoms as strings, other non-JSON terms inspected.
  defp encode(%DateTime{} = time), do: DateTime.to_iso8601(time)

  defp encode(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, encode(v)} end)

  defp encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  defp encode(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp encode(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp encode(string) when is_binary(string),
    do: if(String.valid?(string), do: string, else: inspect(string))

  defp encode(other), do: inspect(other)
end
