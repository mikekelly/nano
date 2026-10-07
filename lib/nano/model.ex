defmodule Nano.Model do
  @moduledoc """
  Which provider serves a model, by the slug's prefix: `openai-codex/<model>` runs on the
  ChatGPT subscription connected to this node (`Nano.ChatGPT`), anything else on OpenRouter
  (`Nano.OpenRouter`). Both take and return the same shapes, so the agent need not know which.
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

  @doc "Models for the start form: the ChatGPT subscription's (when connected) first, then OpenRouter's."
  def models do
    chatgpt = for m <- Nano.ChatGPT.models(), do: %{m | id: @prefix <> m.id}
    chatgpt ++ Nano.OpenRouter.models()
  end
end
