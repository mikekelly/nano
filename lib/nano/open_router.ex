defmodule Nano.OpenRouter do
  @moduledoc """
  One attempt at OpenRouter's OpenAI-compatible chat completions endpoint, with `Req`.
  Retries, backoff and `model_error` logging live in `NanoAgent`.

  Prompt caching: the first (system) message and the last message are sent as text blocks
  with `cache_control: %{type: "ephemeral"}`; the transcript itself is append-only, so the
  prefix stays stable between requests. Usage accounting is requested on every call.

  Images: a message's `"images"` (`Nano.Image` references) are sent after its text as
  `image_url` parts with a base64 `data:` URL, each after a text part saying how it prints.
  Tool messages cannot carry images on every provider, so the images of a run of tool results
  follow it in one user message.
  """

  # "off", then OpenRouter's unified reasoning effort levels, lowest first.
  @reasoning_levels ~w(off minimal low medium high xhigh max)

  @doc """
  The reasoning settings an agent can use: `"off"`, then OpenRouter's effort levels, lowest
  first. Some models support only some levels; OpenRouter maps or rejects the others.
  """
  def reasoning_levels, do: @reasoning_levels

  @doc """
  `{:ok, %{message, finish_reason, usage, provider, cost}} | {:error, %{status, body}}`.
  `messages` are OpenAI-format maps with string keys, system message first. `reasoning` is one
  of `reasoning_levels/0`: `"off"` is sent explicitly (`reasoning.enabled: false`), since some
  models reason by default; a level is sent as `reasoning.effort`. `max_output`, unless nil, is
  sent as `max_tokens`: the most tokens the response may have, reasoning included on most
  providers (OpenRouter takes up to the context length less the prompt). `status` is nil when
  no HTTP response was received.
  """
  def chat(model, messages, tools, reasoning \\ "off", max_output \\ nil) do
    key = Application.get_env(:nano, :openrouter_api_key)

    body = %{
      model: model,
      messages: messages |> images() |> cache(),
      tools: tools,
      usage: %{include: true},
      reasoning: if(reasoning == "off", do: %{enabled: false}, else: %{effort: reasoning})
    }

    body = if max_output, do: Map.put(body, :max_tokens, max_output), else: body

    opts = [json: body, auth: {:bearer, key}, retry: false, receive_timeout: 600_000]

    case Req.post(
           Application.fetch_env!(:nano, :openrouter_base_url) <> "/chat/completions",
           opts
         ) do
      {:ok, %{status: 200, body: resp}} when is_map(resp) ->
        completion(resp)

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: bounded_error(body)}}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  # Some upstreams return HTTP 200 with an error choice, including a nil message and
  # zero usage. It is a failed attempt, not a successful empty assistant response.
  defp completion(%{"error" => error} = resp) when not is_nil(error),
    do: {:error, %{status: 200, body: bounded_error(resp)}}

  defp completion(%{"choices" => [choice | _]} = resp) when is_map(choice) do
    cond do
      choice["finish_reason"] == "error" or not is_nil(choice["error"]) ->
        error = choice["error"] || %{"message" => "Provider reported finish_reason:error"}
        {:error, %{status: 200, body: bounded_error(Map.put(resp, "error", error))}}

      not valid_message?(choice["message"]) or not valid_usage?(resp["usage"] || %{}) ->
        malformed_completion(resp)

      true ->
        usage = resp["usage"] || %{}

        {:ok,
         %{
           message: choice["message"],
           finish_reason: choice["finish_reason"],
           usage: usage,
           provider: resp["provider"],
           cost: usage["cost"]
         }}
    end
  end

  defp completion(resp), do: malformed_completion(resp)

  defp valid_message?(%{} = message) do
    (is_nil(message["content"]) or is_binary(message["content"])) and
      (is_nil(message["tool_calls"]) or
         (is_list(message["tool_calls"]) and
            Enum.all?(message["tool_calls"], fn call ->
              is_map(call) and is_binary(call["id"]) and is_map(call["function"]) and
                is_binary(call["function"]["name"])
            end)))
  end

  defp valid_message?(_), do: false

  defp valid_usage?(usage) when is_map(usage) do
    counts = ~w(prompt_tokens completion_tokens)
    details = usage["prompt_tokens_details"]
    cost = usage["cost"]

    Enum.all?(counts, &(is_nil(usage[&1]) or (is_integer(usage[&1]) and usage[&1] >= 0))) and
      (is_nil(details) or
         (is_map(details) and
            (is_nil(details["cached_tokens"]) or
               (is_integer(details["cached_tokens"]) and details["cached_tokens"] >= 0)))) and
      (is_nil(cost) or (is_number(cost) and cost >= 0))
  end

  defp valid_usage?(_), do: false

  defp malformed_completion(resp) do
    error = %{"code" => 502, "message" => "Malformed provider completion"}
    {:error, %{status: 200, body: bounded_error(Map.put(resp, "error", error))}}
  end

  # Retain error codes for the existing transient classifier, while bounding error
  # payloads before they enter every later agent turn. No provider key/request body.
  defp bounded_error(body) do
    json = Jason.encode!(body)

    if byte_size(json) <= 16_384 do
      body
    else
      error = if is_map(body), do: body["error"], else: nil
      code = if is_map(error) and is_integer(error["code"]), do: error["code"], else: nil

      %{
        "error" => %{"code" => code, "message" => "Provider error payload truncated"},
        "truncated" => true,
        "preview" => utf8_prefix(json, 12_000)
      }
    end
  end

  defp utf8_prefix(text, bytes) do
    prefix = binary_part(text, 0, min(bytes, byte_size(text)))
    if String.valid?(prefix), do: prefix, else: utf8_prefix(prefix, byte_size(prefix) - 1)
  end

  @doc """
  OpenRouter's models as `%{id, name, context_length, images, max_output, prompt_price,
  completion_price, reasoning_levels, default_reasoning}` (`images` whether it takes image
  input, from `architecture.input_modalities`; `max_output` the most tokens its top provider will
  generate in one response, or nil; prices in USD per million tokens, nil if not given;
  levels as `Nano.Model.reasoning/3` gives them), sorted by id. Cached for an hour, a failure for a
  minute; `[]` if they cannot be fetched (5 s at most).
  """
  def models do
    now = System.monotonic_time(:second)

    case :persistent_term.get({__MODULE__, :models}, nil) do
      {until, models} when until > now ->
        models

      _ ->
        models = fetch_models()

        :persistent_term.put(
          {__MODULE__, :models},
          {now + if(models == [], do: 60, else: 3600), models}
        )

        models
    end
  end

  defp fetch_models do
    key = Application.get_env(:nano, :openrouter_api_key)
    auth = if key in [nil, ""], do: [], else: [auth: {:bearer, key}]
    opts = [retry: false, receive_timeout: 5_000, connect_options: [timeout: 5_000]] ++ auth
    url = Application.fetch_env!(:nano, :openrouter_base_url) <> "/models"
    {:ok, %{status: 200, body: %{"data" => data}}} = Req.get(url, opts)
    price = &with({p, _} <- Float.parse(&1 || ""), do: p * 1_000_000, else: (_ -> nil))

    data
    |> Enum.map(fn m ->
      # A model without a reasoning block does not reason: "off" is its only level.
      r = m["reasoning"] || %{"supported_efforts" => ["none"]}

      Map.merge(
        %{
          id: m["id"],
          name: m["name"],
          context_length: m["context_length"],
          images: "image" in (get_in(m, ["architecture", "input_modalities"]) || []),
          max_output: get_in(m, ["top_provider", "max_completion_tokens"]),
          prompt_price: price.(get_in(m, ["pricing", "prompt"])),
          completion_price: price.(get_in(m, ["pricing", "completion"]))
        },
        Nano.Model.reasoning(
          r["supported_efforts"] || [],
          r["mandatory"] != true,
          r["default_effort"]
        )
      )
    end)
    |> Enum.sort_by(& &1.id)
  catch
    _, _ -> []
  end

  @doc """
  Whether a failed attempt is worth retrying: no response at all, 408, 429, 5xx, or a 200
  whose body is an error object with one of those codes (OpenRouter reports some upstream
  failures that way).
  """
  def transient?(%{status: status, body: body}) do
    code = if status == 200, do: is_map(body) && get_in(body, ["error", "code"]), else: status
    code in [nil, false, 408, 429] or (is_integer(code) and code >= 500)
  end

  defp images(messages) do
    messages
    |> Enum.chunk_by(&(&1["role"] == "tool"))
    |> Enum.flat_map(fn
      [%{"role" => "tool"} | _] = results ->
        refs = Enum.flat_map(results, &(&1["images"] || []))
        text = "<harness>The images in the results above:</harness>"
        results = Enum.map(results, &Map.delete(&1, "images"))

        if refs == [],
          do: results,
          else: results ++ [%{"role" => "user", "content" => parts(text, refs)}]

      messages ->
        for m <- messages do
          case Map.pop(m, "images") do
            {nil, m} -> m
            {refs, m} -> %{m | "content" => parts(m["content"], refs)}
          end
        end
    end)
  end

  # Text first, then the images, as OpenRouter recommends. Detail "high", as the Codex CLI
  # sends it, so OpenAI models never take the larger "original" (other providers ignore it).
  defp parts(text, refs) do
    [
      %{"type" => "text", "text" => text}
      | for part <- Nano.Image.parts(refs) do
          case part do
            {:text, text} ->
              %{"type" => "text", "text" => text}

            {:image, url} ->
              %{"type" => "image_url", "image_url" => %{"url" => url, "detail" => "high"}}
          end
        end
    ]
  end

  defp cache([system | rest]), do: [mark(system) | List.update_at(rest, -1, &mark/1)]

  # A message with images: its last text part, since cache_control goes on text.
  defp mark(%{"content" => [_ | _] = parts} = message) do
    i = length(parts) - 1 - Enum.find_index(Enum.reverse(parts), &(&1["type"] == "text"))
    mark = &Map.put(&1, "cache_control", %{"type" => "ephemeral"})
    %{message | "content" => List.update_at(parts, i, mark)}
  end

  defp mark(%{"content" => text} = message) when is_binary(text) and text != "" do
    %{
      message
      | "content" => [
          %{"type" => "text", "text" => text, "cache_control" => %{"type" => "ephemeral"}}
        ]
    }
  end

  defp mark(message), do: message
end
