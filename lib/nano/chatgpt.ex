defmodule Nano.ChatGPT do
  @moduledoc """
  Models served by a ChatGPT subscription (Plus or Pro), the way the Codex CLI and pi use one:
  the OpenAI Responses API at the Codex backend (`CHATGPT_BASE_URL`), authorised by the tokens
  `Nano.ChatGPT.Auth` holds. Inference is flat-rate under the plan's usage limits, so a
  response has no cost.

  The agent's history stays in chat completions form; this module translates at the edge.
  The system message becomes `instructions` (as pi sends it); user, assistant and tool
  messages become input items; the tools become Responses function tools. Requests are
  stateless and streamed (`store: false`, `stream: true`), as both clients always send them,
  so each response's reasoning items, with their encrypted content, are kept in the assistant
  message's `reasoning_details` and sent back in later requests. No bound on the response is
  sent: the backend refuses `max_output_tokens` with a 400, and neither client sends it. The
  event stream is read whole and returned in the shape `Nano.OpenRouter.chat/5` returns.

  Sources: openai/codex `codex-rs/core/src/client.rs`, `codex-rs/codex-api/src/sse/`, and
  badlogic/pi-mono `packages/ai/src/api/openai-codex-responses.ts`.
  """

  # Used when the backend's own list cannot be had: the models it listed on 2026-10-07, in its
  # order of priority (gpt-5.5, hidden then, retires on 2026-10-14). The levels and defaults are
  # an approximation: gpt-6.x's on that day.
  @known for(
           id <-
             ~w(gpt-6.1-sol gpt-6-astra gpt-6-sol gpt-6-luna gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna),
           do: %{
             id: id,
             name: id,
             context_length: 272_000,
             reasoning_levels: ~w(low medium high xhigh max),
             default_reasoning: if(id == "gpt-6.1-sol", do: "low", else: "medium")
           }
         )

  @doc "As `Nano.Model.chat/5`, for `model` without its `openai-codex/` prefix, and unbounded."
  def chat(model, messages, tools, reasoning) do
    case Nano.ChatGPT.Auth.token() do
      {:ok, creds} -> request(model, messages, tools, reasoning, creds, true)
      {:error, message} -> {:error, %{status: nil, body: message}}
    end
  end

  defp request(model, [%{"role" => "system"} = system | rest], tools, reasoning, creds, again?) do
    # Same prompt, same key: requests from one agent share a cache (pi caps keys at 64 chars).
    key = "nano-" <> String.slice(sha(system["content"]), 0, 32)

    body = %{
      model: model,
      instructions: system["content"],
      input: Enum.flat_map(rest, &input/1),
      tools: for(%{function: f} <- tools, do: Map.merge(f, %{type: "function", strict: false})),
      tool_choice: "auto",
      parallel_tool_calls: true,
      reasoning: reasoning(reasoning),
      store: false,
      stream: true,
      include: ["reasoning.encrypted_content"],
      prompt_cache_key: key
    }

    case Req.post(url("/responses"),
           json: body,
           headers: [{"session-id", key} | headers(creds)],
           retry: false,
           receive_timeout: 600_000
         ) do
      {:ok, %{status: 200, body: stream}} when is_binary(stream) ->
        stream |> events() |> response()

      # The token was refused although not expired: refresh it once and try again (as codex does).
      {:ok, %{status: 401}} when again? ->
        case Nano.ChatGPT.Auth.refresh(creds.access_token) do
          {:ok, creds} -> request(model, [system | rest], tools, reasoning, creds, false)
          {:error, message} -> {:error, %{status: 401, body: message}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, error(status, body)}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception), transient: true}}
    end
  end

  # The originator names this client; the backend does not require Codex's (pi sends "pi").
  defp headers(creds),
    do: [
      {"authorization", "Bearer " <> creds.access_token},
      {"chatgpt-account-id", creds.account_id},
      {"originator", "nano"},
      {"accept", "text/event-stream"}
    ]

  # The agent's level as the backend's effort, as pi maps them: "off" asks for none, and
  # "minimal", which these models lack, for their least, "low". The rest are sent as they are;
  # a model without one ("max" on gpt-5.5) rejects it, as on OpenRouter.
  defp reasoning("off"), do: %{effort: "none"}
  defp reasoning("minimal"), do: %{effort: "low", summary: "auto"}
  defp reasoning(level), do: %{effort: level, summary: "auto"}

  ## Chat messages to Responses input items

  defp input(%{"role" => "user", "content" => text}),
    do: [%{type: "message", role: "user", content: [%{type: "input_text", text: text}]}]

  # Reasoning first, as the model produced it, then the text, then the calls.
  defp input(%{"role" => "assistant"} = m) do
    reasoning = for %{"type" => "reasoning"} = item <- m["reasoning_details"] || [], do: item

    text =
      for text <- [m["content"]], text not in [nil, ""] do
        %{type: "message", role: "assistant", content: [%{type: "output_text", text: text}]}
      end

    calls =
      for c <- m["tool_calls"] || [] do
        args = c["function"]["arguments"]

        %{
          type: "function_call",
          call_id: c["id"],
          name: c["function"]["name"],
          arguments: if(is_binary(args), do: args, else: Jason.encode!(args || %{}))
        }
      end

    reasoning ++ text ++ calls
  end

  defp input(%{"role" => "tool"} = m),
    do: [%{type: "function_call_output", call_id: m["tool_call_id"], output: m["content"]}]

  ## The event stream to a chat completions response

  # Server-sent events: blocks separated by a blank line, JSON in their data lines.
  defp events(stream) do
    for block <- String.split(stream, ~r/\r?\n\r?\n/),
        data = for("data:" <> d <- String.split(block, ~r/\r?\n/), do: String.trim(d)),
        {:ok, %{} = event} <- [Jason.decode(Enum.join(data, "\n"))],
        do: event
  end

  @ends ~w(response.completed response.done response.incomplete response.failed error)

  defp response(events) do
    case Enum.find(events, &(&1["type"] in @ends)) do
      %{"type" => "response.failed", "response" => r} -> {:error, error(200, r)}
      %{"type" => "error"} = e -> {:error, error(200, %{"error" => e})}
      %{"response" => r} -> {:ok, message(r, events)}
      nil -> {:error, %{status: 200, body: "the event stream ended early", transient: true}}
    end
  end

  # The final items: the completed response's output, else each item as it was done (pi takes
  # the completed copy where the streamed one lacks the encrypted reasoning).
  defp message(r, events) do
    items =
      case r["output"] do
        [_ | _] = output -> output
        _ -> for %{"type" => "response.output_item.done", "item" => item} <- events, do: item
      end

    texts =
      for %{"type" => "message", "content" => content} <- items,
          %{"type" => "output_text", "text" => text} <- content,
          do: text

    calls =
      for %{"type" => "function_call"} = c <- items do
        %{
          "id" => c["call_id"],
          "type" => "function",
          "function" => %{"name" => c["name"], "arguments" => c["arguments"]}
        }
      end

    reasoning = for %{"type" => "reasoning"} = item <- items, do: Map.delete(item, "status")
    summary = for %{"summary" => parts} <- reasoning, %{"text" => text} <- parts, do: text
    usage = r["usage"] || %{}

    %{
      message:
        %{"role" => "assistant", "content" => if(texts != [], do: Enum.join(texts))}
        |> put("tool_calls", calls)
        |> put("reasoning", if(summary != [], do: Enum.join(summary, "\n\n")))
        |> put("reasoning_details", reasoning),
      finish_reason:
        cond do
          r["status"] == "incomplete" -> get_in(r, ["incomplete_details", "reason"]) || "length"
          calls != [] -> "tool_calls"
          true -> "stop"
        end,
      # OpenAI's input_tokens include the cached ones, as OpenRouter's prompt_tokens do.
      usage: %{
        "prompt_tokens" => usage["input_tokens"] || 0,
        "completion_tokens" => usage["output_tokens"] || 0,
        "prompt_tokens_details" => %{
          "cached_tokens" => get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0
        },
        "completion_tokens_details" => %{
          "reasoning_tokens" => get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0
        }
      },
      provider: "ChatGPT",
      cost: nil
    }
  end

  defp put(map, _key, value) when value in [nil, []], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  ## Errors

  # Codex's classification (codex-api/src/api_bridge.rs, sse/responses_error.rs): a usage
  # limit, or a model the plan lacks, is final and halts the agent; quota and context errors
  # are final; other rate limits, server errors and unknown stream failures are retried.
  @final ~w(context_length_exceeded insufficient_quota credit_balance_exhausted invalid_prompt)
  @limits ~w(usage_limit_reached usage_not_included)

  defp error(status, body) do
    e = if is_map(body) and is_map(body["error"]), do: body["error"], else: %{}
    kind = Enum.find([e["type"], e["code"]], &(&1 in @limits)) || e["code"]

    cond do
      kind in @limits ->
        %{status: status, body: body, limit: limit(kind, e)}

      status == 200 ->
        %{status: status, body: body, transient: kind not in @final}

      true ->
        final = kind in @final or String.ends_with?(to_string(kind), "_spend_limit_exceeded")

        %{
          status: status,
          body: body,
          transient: not final and (status in [408, 429] or status >= 500)
        }
    end
  end

  defp limit(kind, e) do
    plan = if e["plan_type"], do: " (#{e["plan_type"]})", else: ""

    what =
      if kind == "usage_not_included",
        do: "The ChatGPT plan#{plan} this node uses for you does not include this model",
        else: "The ChatGPT plan#{plan} this node uses for you has reached its usage limit"

    case e["resets_at"] do
      at when is_integer(at) ->
        what <> " until #{at |> DateTime.from_unix!() |> DateTime.to_iso8601()}"

      _ ->
        what
    end
  end

  ## Models

  @doc """
  The models the connected subscription offers, as `%{id, name, context_length,
  reasoning_levels, default_reasoning}` (ids without the `openai-codex/` prefix; levels as
  `Nano.Model.reasoning/3` gives them): the backend's list (`GET /models`, as the Codex CLI
  fetches it, in its order of priority), or the Codex CLI's bundled list if that cannot be had;
  `[]` when no subscription is connected. Cached for an hour, a fallback for a minute.
  """
  def models do
    now = System.monotonic_time(:second)
    cached = :persistent_term.get({__MODULE__, :models}, nil)

    cond do
      Nano.ChatGPT.Auth.status().status != :connected ->
        []

      match?({until, _} when until > now, cached) ->
        elem(cached, 1)

      true ->
        {ttl, models} =
          case fetch_models() do
            [] -> {60, @known}
            list -> {3600, list}
          end

        :persistent_term.put({__MODULE__, :models}, {now + ttl, models})
        models
    end
  end

  defp fetch_models do
    {:ok, creds} = Nano.ChatGPT.Auth.token()
    opts = [headers: headers(creds), retry: false, receive_timeout: 5_000]

    {:ok, %{status: 200, body: %{"models" => models}}} =
      Req.get(url("/models?client_version=#{client_version()}"), opts)

    # In the catalog's `priority` order, lowest first, as the Codex CLI's picker lists them.
    # The context is `context_window`, the size Codex works within; gpt-6.x also list a larger
    # `max_context_window` (872,000 on 2026-10-07), not used here. Codex models reason unless
    # they list effort "none"; "ultra" (delegating to sub-agents) has no level here.
    for m <- Enum.sort_by(models, & &1["priority"]), m["visibility"] in [nil, "list"] do
      efforts = for %{"effort" => e} <- m["supported_reasoning_levels"] || [], do: e

      Map.merge(
        %{
          id: m["slug"],
          name: m["display_name"] || m["slug"],
          context_length: m["context_window"]
        },
        Nano.Model.reasoning(efforts, false, m["default_reasoning_level"])
      )
    end
  catch
    _, _ -> []
  end

  # The backend lists only the models released to clients at least this new: on 2026-10-07,
  # gpt-6.1-sol from 0.159.0. Keep it at the Codex CLI's latest release.
  defp client_version, do: Application.fetch_env!(:nano, :chatgpt_client_version)

  defp url(path), do: Application.fetch_env!(:nano, :chatgpt_base_url) <> path
  defp sha(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
end
