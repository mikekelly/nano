defmodule Nano.Model do
  @moduledoc """
  Which provider serves a model, by the slug's prefix: `openai-codex/<model>` runs on the
  ChatGPT subscription connected to this node (`Nano.ChatGPT`), anything else on OpenRouter
  (`Nano.OpenRouter`), if the node has its key (`openrouter?/0`, a setting an operator can
  change at any time). Both take and return the same
  shapes, so the agent need not know which. The model lists of both are checked here, in one place, before an agent starts (`check/3`).
  The start form picks a provider, then a model there, and joins them back into a slug.
  """

  @doc "Catalog input modalities; absent or malformed metadata is conservatively text-only."
  def input_modalities(values) when is_list(values) do
    case Enum.filter(values, &is_binary/1) |> Enum.uniq() do
      [] -> ["text"]
      modalities -> modalities
    end
  end

  def input_modalities(_), do: ["text"]

  @prefix "openai-codex/"

  @doc """
  One model call: `{:ok, %{message, finish_reason, usage, provider, cost}}` or `{:error, %{status,
  body, class}}`, with `message` and `usage` in OpenRouter's chat completions shape (`status` is
  nil when no HTTP response came). `max_output` bounds the response's tokens, reasoning
  included, on OpenRouter (`max_tokens`). The ChatGPT subscription is sent no bound: its backend
  refuses `max_output_tokens` with a 400 (the Codex CLI and pi never send it), and the window
  its list gives is the input Codex works within, below the model's whole window.

  Each provider sorts its failures into one `class`, which decides what `NanoAgent` does:

    * `:transient`: no response, a timeout, a cut stream, a rate limit, an overloaded or failing
      server. Worth retrying, after `retry_after:` milliseconds when the provider said how long.
    * `:usage_limit`: a plan's usage limit or an account's credit is used up; `limit:` says which,
      in a sentence. The agent halts until an operator un-halts it.
    * `:auth`: the provider refused this node's credentials (after the ChatGPT subscription's
      one refresh). The agent halts, `:provider_unavailable`.
    * `:context`: the request does not fit the model's context. The agent halts, `:context`.
    * `:refused`: the request is invalid, and sending it again would not change that (a 4xx
      such as an unsupported parameter). The agent halts, `:model_refused`.
  """
  def chat(@prefix <> model, messages, tools, reasoning, _max_output),
    do: Nano.ChatGPT.chat(model, messages, tools, reasoning)

  def chat(model, messages, tools, reasoning, max_output),
    do: Nano.OpenRouter.chat(model, messages, tools, reasoning, max_output)

  @doc """
  The class (see `chat/5`) of an HTTP failure, by its status: none at all, 408, 409, 425, 429
  or 5xx is `:transient`; 401 is `:auth`; 413, or a 400 or 422 whose message says the request
  is too long for the context, is `:context`; any other 4xx is `:refused`. Providers decide
  their own error codes first.
  """
  def class(status, body) do
    cond do
      status in [nil, 408, 409, 425, 429] or status >= 500 -> :transient
      status == 401 -> :auth
      status == 413 or (status in [400, 422] and context?(message(body))) -> :context
      true -> :refused
    end
  end

  # How providers say a request is longer than the model's context (pi lists the many ways in
  # packages/ai/src/utils/overflow.ts; these are the common ones).
  defp context?(text),
    do:
      text =~
        ~r/context[ _](length|window)|maximum context|prompt is too long|input is too long|exceeds? the (model's )?context|too many tokens/i

  @doc """
  Milliseconds the provider asked to wait before trying again, or nil: from a `retry-after-ms`
  header, a `retry-after` header in seconds (an HTTP date is not read), or a message saying
  "try again in 1.5s" (OpenAI's rate limits, as the Codex CLI reads them). `headers` as `Req`
  gives them.
  """
  def retry_after(headers, body) do
    header = fn name -> List.first(Map.get(headers, name, [])) end

    cond do
      ms = header.("retry-after-ms") -> number(ms)
      s = header.("retry-after") -> number(s, 1000)
      m = Regex.run(~r/try again in\s*(\d+(?:\.\d+)?)\s*(ms|s)/i, message(body)) -> later(m)
      true -> nil
    end
  end

  defp later([_, n, unit]), do: number(n, if(String.downcase(unit) == "ms", do: 1, else: 1000))

  defp number(text, scale \\ 1) do
    case Float.parse(String.trim(text)) do
      {n, ""} when n >= 0 -> round(n * scale)
      _ -> nil
    end
  end

  @doc """
  What a provider said about a failure, as text: the error object's message (or code), or the
  body itself.
  """
  def message(body) do
    error = if is_map(body), do: body["error"] || body, else: body

    cond do
      is_binary(error) ->
        error

      is_map(error) and is_binary(error["message"]) ->
        error["message"]

      is_map(error) and (error["code"] || error["type"]) ->
        to_string(error["code"] || error["type"])

      true ->
        inspect(body, limit: 10, printable_limit: 300)
    end
  end

  @doc "The provider of an agent's model, by name: \"OpenRouter\" or \"the ChatGPT subscription\"."
  def provider(model), do: model |> split() |> elem(0) |> name()

  @doc """
  What `NanoAgent.start/1` checks of an agent's model, against its provider's model list: that
  the provider can be called now and lists the model, that `reasoning` is one of the model's
  levels, and that `max_context` is from 1 to the model's context window. `{:ok, entry}`, the
  model's entry in the list, or `{:error, message}` saying what to do instead. A model whose
  limits cannot be verified, because the list cannot be had or gives no window, is refused.
  """
  def check(model, reasoning, max_context) do
    with {:ok, entry} <- lookup(model) do
      levels = Enum.join(entry.reasoning_levels, ", ")
      window = entry.context_length

      cond do
        reasoning == nil ->
          {:error,
           "missing reasoning: #{model} supports #{levels} (its default is #{entry.default_reasoning})"}

        reasoning not in entry.reasoning_levels ->
          {:error,
           "reasoning #{inspect(reasoning)} is not supported by #{model}; supported: #{levels}"}

        not is_integer(window) ->
          {:error,
           "could not verify the context window of #{model}: its provider lists none, so no " <>
             "agent can be started on it"}

        max_context == nil ->
          {:error,
           "missing max_context: #{model}'s context window is #{window}; give a number of " <>
             "tokens from 1 to #{window}"}

        not (is_integer(max_context) and max_context in 1..window) ->
          {:error,
           "max_context must be a whole number of tokens from 1 to #{window}, #{model}'s " <>
             "context window (there is no unlimited context), not #{inspect(max_context)}"}

        true ->
          {:ok, entry}
      end
    end
  end

  @doc "A model's entry in its provider's list (see `check/3`), or `{:error, message}`."
  def lookup(model) when model in [nil, ""],
    do:
      {:error,
       "missing model: give a model slug, openai-codex/<model> for the ChatGPT subscription " <>
         "or an OpenRouter model id such as deepseek/deepseek-v4.1-flash"}

  def lookup(model) when not is_binary(model),
    do: {:error, "model must be a slug (a string), not #{inspect(model)}"}

  def lookup(model) do
    {provider, id} = split(model)

    with nil <- unavailable(provider) do
      models = models(provider)

      case Enum.find(models, &(&1.id == id)) do
        _ when models == [] ->
          {:error,
           "could not verify #{model}'s context window and reasoning levels: " <>
             "#{name(provider)}'s model list could not be fetched; try again in a minute"}

        nil when provider == :chatgpt ->
          ids = Enum.map_join(models, ", ", &slug(:chatgpt, &1.id))
          {:error, "unknown model #{model}: the ChatGPT subscription offers #{ids}"}

        nil ->
          {:error,
           "unknown model #{model}: OpenRouter does not list it; its model ids are at " <>
             "https://openrouter.ai/models"}

        entry ->
          {:ok, entry}
      end
    end
  end

  @doc "A provider's model list: `Nano.OpenRouter.models/0` or `Nano.ChatGPT.models/0`."
  def models(:openrouter), do: Nano.OpenRouter.models()
  def models(:chatgpt), do: Nano.ChatGPT.models()

  defp name(:openrouter), do: "OpenRouter"
  defp name(:chatgpt), do: "the ChatGPT subscription"

  # Why the provider cannot be called now, as {:error, message}, or nil.
  defp unavailable(:chatgpt) do
    if Nano.ChatGPT.Auth.status().status != :connected,
      do:
        {:error,
         "the ChatGPT subscription is not connected: connect it from the dashboard's start " <>
           "form (Connect ChatGPT) or with POST /api/chatgpt/login"}
  end

  defp unavailable(:openrouter) do
    if not openrouter?(),
      do:
        {:error,
         "OpenRouter is off on this node (it has no OpenRouter API key); use an " <>
           "openai-codex/ model on the ChatGPT subscription, or set the openrouter_api_key " <>
           "setting (dashboard Settings, or PUT /api/settings/openrouter_api_key)"}
  end

  @doc "Whether OpenRouter is on: the node has its key (setting `openrouter_api_key`), now."
  def openrouter?, do: Nano.Settings.get(:openrouter_api_key) != nil

  @doc """
  Whether the provider of an agent's model has been turned off: OpenRouter's key removed. The
  ChatGPT subscription's connection is not checked here; its requests say when it is gone.
  """
  def off?(model), do: match?({:openrouter, _}, split(model)) and not openrouter?()

  @doc """
  The `reasoning_levels` and `default_reasoning` of an entry of either provider's model list
  (`Nano.OpenRouter.models/0`, `Nano.ChatGPT.models/0`), from the efforts the provider lists for
  the model and its default effort: the levels of `NanoAgent.reasoning_levels/0` the model
  supports, lowest first. `"none"` is `"off"`, the others go by name, and efforts with no level
  here are dropped; no efforts listed means the provider takes any level. `"off"` is also
  supported when `off?`. Without a default, the lowest level supported.
  """
  def reasoning(efforts, off?, default) do
    efforts = Enum.map(efforts, &level/1)

    levels =
      for l <- NanoAgent.reasoning_levels(),
          if(l == "off", do: off? or l in efforts, else: efforts == [] or l in efforts),
          do: l

    %{reasoning_levels: levels, default_reasoning: level(default) || List.first(levels)}
  end

  defp level("none"), do: "off"
  defp level(effort), do: if(effort in NanoAgent.reasoning_levels(), do: effort)

  @doc """
  A slug as its provider and the model's name there: `{:chatgpt, "gpt-5.5"}` for
  `openai-codex/gpt-5.5`, `{:openrouter, slug}` for anything else.
  """
  def split(@prefix <> model), do: {:chatgpt, model}
  def split(slug), do: {:openrouter, slug}

  @doc "The slug for a provider's model; the inverse of `split/1`."
  def slug(:chatgpt, model), do: @prefix <> model
  def slug(:openrouter, model), do: model
end
