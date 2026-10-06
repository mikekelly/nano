defmodule Nano.OpenRouter do
  @moduledoc """
  One attempt at OpenRouter's OpenAI-compatible chat completions endpoint, with `Req`.
  Retries, backoff and `model_error` logging live in `NanoAgent`.

  Prompt caching: the first (system) message and the last message are sent as text blocks
  with `cache_control: %{type: "ephemeral"}`; the transcript itself is append-only, so the
  prefix stays stable between requests. Usage accounting is requested on every call.
  """

  @doc """
  `{:ok, %{message, finish_reason, usage, provider, cost}} | {:error, %{status, body}}`.
  `messages` are OpenAI-format maps with string keys, system message first. `status` is nil
  when no HTTP response was received.
  """
  def chat(model, messages, tools) do
    key = Application.get_env(:nano, :openrouter_api_key)
    body = %{model: model, messages: cache(messages), tools: tools, usage: %{include: true}}

    opts = [json: body, auth: {:bearer, key}, retry: false, receive_timeout: 600_000]

    case Req.post(
           Application.fetch_env!(:nano, :openrouter_base_url) <> "/chat/completions",
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
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception)}}
    end
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

  defp mark(message), do: message
end
