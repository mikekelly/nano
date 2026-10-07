defmodule Nano.Model do
  @moduledoc """
  Which provider serves a model, by the slug's prefix: `openai-codex/<model>` runs on the
  ChatGPT subscription connected to this node (`Nano.ChatGPT`), anything else on OpenRouter
  (`Nano.OpenRouter`). Both take and return the same shapes, so the agent need not know which.
  The start form picks a provider, then a model there, and joins them back into a slug.
  """

  @prefix "openai-codex/"

  @doc """
  One model call: `{:ok, %{message, finish_reason, usage, provider, cost}}` or `{:error, %{status,
  body}}`, with `message` and `usage` in OpenRouter's chat completions shape. An error may also
  carry `transient: true` (worth retrying) and `limit:` (a sentence saying which usage limit was
  reached, for the agent's halt note).
  """
  def chat(@prefix <> model, messages, tools, reasoning),
    do: Nano.ChatGPT.chat(model, messages, tools, reasoning)

  def chat(model, messages, tools, reasoning) do
    with {:error, error} <- Nano.OpenRouter.chat(model, messages, tools, reasoning),
         do: {:error, Map.put(error, :transient, Nano.OpenRouter.transient?(error))}
  end

  @doc "Why an agent on `model` could not call it now, or nil: what `NanoAgent.start/1` checks."
  def unavailable(@prefix <> _) do
    if Nano.ChatGPT.Auth.status().status != :connected, do: :chatgpt_not_connected
  end

  def unavailable(_) do
    if Application.get_env(:nano, :openrouter_api_key) in [nil, ""],
      do: :missing_openrouter_api_key
  end

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
  The level the start form chooses for an entry of a model list (or nil, a model not listed):
  `REASONING` if the model supports it, else the model's default (if it has any level here).
  """
  def default_reasoning(model) do
    level = Application.get_env(:nano, :reasoning)

    if model == nil or level in model.reasoning_levels,
      do: level,
      else: model.default_reasoning || level
  end

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
