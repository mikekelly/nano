defmodule Nano.OpenRouter do
  @moduledoc """
  One attempt at OpenRouter's OpenAI-compatible chat completions endpoint, with `Req`.
  Retries, backoff and `model_error` logging live in `NanoAgent`.

  Prompt caching: the first (system) message and the last message are sent as text blocks
  with `cache_control: %{type: "ephemeral"}`; the transcript itself is append-only, so the
  prefix stays stable between requests. Usage accounting is requested on every call.
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
    key = Nano.Settings.get(:openrouter_api_key)

    body = %{
      model: model,
      messages: messages |> Vega.Images.openrouter() |> cache(),
      tools: tools,
      usage: %{include: true},
      reasoning: if(reasoning == "off", do: %{enabled: false}, else: %{effort: reasoning})
    }

    body = if max_output, do: Map.put(body, :max_tokens, max_output), else: body

    opts = [json: body, auth: {:bearer, key}, retry: false, receive_timeout: 600_000]

    case Req.post(
           base_url() <> "/chat/completions",
           opts
         ) do
      {:ok, %{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
        usage = resp["usage"] || %{}

        {:ok,
         %{
           message: choice["message"],
           finish_reason: choice["finish_reason"],
           usage: usage,
           provider: resp["provider"],
           cost: usage["cost"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: Vega.Images.redact(body)}}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  @doc """
  OpenRouter's models as `%{id, name, context_length, max_output, prompt_price, completion_price,
  reasoning_levels, default_reasoning}` (`max_output` the most tokens its top provider will
  generate in one response, or nil; prices in USD per million tokens, nil if not given;
  levels as `Nano.Model.reasoning/3` gives them), sorted by id. Cached for an hour, a failure for a
  minute, and fetched again once the key or the address changes; `[]` if they cannot be
  fetched (5 s at most), or OpenRouter is off.
  """
  def models do
    now = System.monotonic_time(:second)
    config = :erlang.phash2({Nano.Settings.get(:openrouter_api_key), base_url()})

    case Nano.Model.openrouter?() && :persistent_term.get({__MODULE__, :models}, nil) do
      false ->
        []

      {^config, until, models} when until > now ->
        models

      _ ->
        models = fetch_models()

        :persistent_term.put(
          {__MODULE__, :models},
          {config, now + if(models == [], do: 60, else: 3600), models}
        )

        models
    end
  end

  defp fetch_models do
    opts = [
      auth: {:bearer, Nano.Settings.get(:openrouter_api_key)},
      retry: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]

    url = base_url() <> "/models"
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
          input_modalities:
            Nano.Model.input_modalities(get_in(m, ["architecture", "input_modalities"])),
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

  defp cache([system | rest]), do: [mark(system) | List.update_at(rest, -1, &mark/1)]

  defp mark(%{"content" => text} = message) when is_binary(text) and text != "" do
    %{
      message
      | "content" => [
          %{"type" => "text", "text" => text, "cache_control" => %{"type" => "ephemeral"}}
        ]
    }
  end

  defp mark(%{"content" => parts} = message) when is_list(parts) do
    # Cache marker on the last text part, never on the binary attachment.
    index =
      parts
      |> Enum.with_index()
      |> Enum.filter(fn {p, _} -> p["type"] == "text" end)
      |> List.last()

    if index do
      {_, i} = index

      Map.put(
        message,
        "content",
        List.update_at(parts, i, &Map.put(&1, "cache_control", %{"type" => "ephemeral"}))
      )
    else
      message
    end
  end

  defp mark(message), do: message

  defp base_url, do: Nano.Settings.get(:openrouter_base_url)
end
