defmodule Nano.Model do
  @moduledoc """
  Which provider serves a model, by the slug's prefix: `openai-codex/<model>` runs on the
  ChatGPT subscription connected to this node (`Nano.ChatGPT`), anything else on OpenRouter
  (`Nano.OpenRouter`), if the node has its key (`openrouter?/0`, a setting an operator can
  change at any time). Both take and return the same
  shapes, so the agent need not know which. The model lists of both are checked here, in one place, before an agent starts (`check/3`).
  The start form picks a provider, then a model there, and joins them back into a slug.
  """

  @prefix "openai-codex/"

  @doc """
  One model call: `{:ok, %{message, finish_reason, usage, provider, cost}}` or `{:error, %{status,
  body}}`, with `message` and `usage` in OpenRouter's chat completions shape. An error may also
  carry `transient: true` (worth retrying) and `limit:` (a sentence saying which usage limit was
  reached, for the agent's halt note). `max_output` bounds the response's tokens, reasoning
  included, on OpenRouter (`max_tokens`). The ChatGPT subscription is sent no bound: its backend
  refuses `max_output_tokens` with a 400 (the Codex CLI and pi never send it), and the window
  its list gives is the input Codex works within, below the model's whole window.
  """
  def chat(@prefix <> model, messages, tools, reasoning, _max_output),
    do: Nano.ChatGPT.chat(model, messages, tools, reasoning)

  def chat(model, messages, tools, reasoning, max_output) do
    with {:error, error} <- Nano.OpenRouter.chat(model, messages, tools, reasoning, max_output),
         do: {:error, Map.put(error, :transient, Nano.OpenRouter.transient?(error))}
  end

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
