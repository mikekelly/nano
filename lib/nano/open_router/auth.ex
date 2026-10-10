defmodule Nano.OpenRouter.Auth do
  @moduledoc """
  Connects OpenRouter with its OAuth PKCE flow (https://openrouter.ai/docs/guides/overview/auth/oauth):
  `login/1` gives the address to send a person to, `https://openrouter.ai/auth` with an S256
  code challenge, a `state` and the dashboard's callback; once they authorize, OpenRouter
  sends their browser back to the callback with a `code`, which `callback/1` exchanges at
  `POST <openrouter_base_url>/auth/keys` for an API key of their own and stores as the
  `openrouter_api_key` setting. OpenRouter accepts localhost callbacks on any port.

  This process only holds the logins under way, each a `state` and its code verifier, for
  15 minutes; a `state` is good once. The exchange runs in the caller. The key goes straight
  into the settings: never logged, never returned.
  """
  use GenServer

  @login_ms 15 * 60_000

  ## API

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Starts a login that returns to `callback_url`: `{:ok, url}`, the address on OpenRouter to
  send the person to, or `{:error, message}`.
  """
  def login(callback_url) do
    {state, verifier} = {random(16), random(32)}
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    with {:ok, ^callback_url} <- NanoWeb.ApiGuard.callback_url(),
         :ok <- call({:put, state, verifier, callback_url}) do
      query = [
        callback_url: callback_url,
        code_challenge: challenge,
        code_challenge_method: "S256",
        state: state,
        key_label: "Nano Agent"
      ]

      {:ok, authorize_url() <> "?" <> URI.encode_query(query)}
    else
      _ -> {:error, "OpenRouter callback policy unavailable or mismatched"}
    end
  end

  @doc """
  Finishes a login from the callback's query parameters (`code`, `state`): the key is stored
  as the `openrouter_api_key` setting. `:ok`, or `{:error, message}` saying why not.
  """
  def callback(%{"code" => code, "state" => state}) when is_binary(code) and is_binary(state) do
    case call({:take, state}) do
      {:ok, verifier} ->
        exchange(code, verifier)

      _ ->
        {:error,
         "this OpenRouter sign-in is unknown, already used or more than 15 minutes old: " <>
           "connect again"}
    end
  end

  def callback(_params),
    do: {:error, "OpenRouter sent no authorization back (was access denied?): connect again"}

  defp exchange(code, verifier) do
    body = %{code: code, code_verifier: verifier, code_challenge_method: "S256"}
    opts = [json: body, retry: false, receive_timeout: 15_000, connect_options: [timeout: 10_000]]

    case Req.post(Nano.Settings.get(:openrouter_base_url) <> "/auth/keys", opts) do
      {:ok, %{status: 200, body: %{"key" => key}}} when is_binary(key) ->
        Nano.Settings.put(:openrouter_api_key, key)

      {:ok, %{status: status, body: body}} ->
        {:error,
         "OpenRouter would not exchange the authorization for a key: #{why(status, body)}"}

      {:error, e} ->
        {:error, "could not reach OpenRouter for the key: #{Exception.message(e)}"}
    end
  end

  # The HTTP status and OpenRouter's error message, never a whole body (a 200 that lacked the
  # expected shape may still hold a key).
  defp why(200, _), do: "HTTP 200 without a key"

  defp why(status, body) do
    case is_map(body) && get_in(body, ["error", "message"]) do
      message when is_binary(message) -> "HTTP #{status}: #{String.slice(message, 0, 200)}"
      _ -> "HTTP #{status}"
    end
  end

  # OpenRouter's authorization page, on the host of its API: https://openrouter.ai/auth.
  defp authorize_url do
    uri = URI.parse(Nano.Settings.get(:openrouter_base_url))
    URI.to_string(%{uri | path: "/auth", query: nil})
  end

  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp call(msg) do
    GenServer.call(__MODULE__, msg, 10_000)
  catch
    :exit, reason ->
      {:error, "the OpenRouter sign-in process did not answer (#{diagnostic_reason(reason)})"}
  end

  ## Server

  @impl true
  def init(nil) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:invalidate_pending, _from, logins), do: {:reply, map_size(logins), %{}}

  def handle_call({:put, state, verifier, callback_url}, _from, logins) do
    login = %{verifier: verifier, expires_at: now() + @login_ms, callback_url: callback_url}
    {:reply, :ok, logins |> current() |> Map.put(state, login)}
  end

  def handle_call({:take, state}, _from, logins) do
    {login, logins} = logins |> current() |> Map.pop(state)

    valid =
      login && is_binary(Map.get(login, :callback_url)) &&
        login.callback_url == configured_callback()

    {:reply, if(valid, do: {:ok, login.verifier}, else: :error), logins}
  end

  # Anyone may call, cast or send this process anything; what it does not know is refused or
  # ignored.
  def handle_call(_msg, _from, logins), do: {:reply, {:error, :unknown_call}, logins}

  @impl true
  def handle_cast(_msg, logins), do: {:noreply, logins}

  @impl true
  def handle_info(_msg, logins), do: {:noreply, logins}

  @impl true
  # OTP passes state, last message, reason and the sys debug log here. Treat all
  # payloads as credentials, including unexpected envelopes and future fields.
  def format_status(status) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, diagnostic_reason(reason)}
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end

  @impl true
  def terminate(reason, _state) when reason in [:normal, :shutdown], do: :ok
  def terminate({:shutdown, _}, _state), do: :ok

  def terminate(reason, _state) do
    # OTP appends the original stack after format_status and proc_lib separately
    # reports queued messages, even for sensitive processes at finite log depth.
    # A tagged shutdown suppresses that second report while gen_server retains a
    # safe failure class/MFA. Production children are permanent and still restart.
    :erlang.raise(
      :exit,
      {:shutdown, {:credential_diagnostic, diagnostic_reason(reason)}},
      diagnostic_stack(reason)
    )
  end

  defp diagnostic_stack({_, stack}) when is_list(stack) do
    for {__MODULE__, callback, arguments, _} <- stack,
        callback in [:handle_call, :handle_cast, :handle_info],
        arity = if(is_list(arguments), do: length(arguments), else: arguments),
        is_integer(arity),
        do: {__MODULE__, callback, arity, []}
  end

  defp diagnostic_stack(_), do: [{__MODULE__, :terminate, 2, []}]

  # Retain only a fixed failure class, never exception arguments or arbitrary atoms.
  defp diagnostic_reason({:shutdown, {:credential_diagnostic, reason}}),
    do: diagnostic_reason(reason)

  defp diagnostic_reason({reason, _}), do: diagnostic_reason(reason)

  defp diagnostic_reason(reason)
       when reason in [
              :badmap,
              :badarg,
              :badarith,
              :badmatch,
              :function_clause,
              :case_clause,
              :undef,
              :timeout,
              :noproc,
              :normal,
              :shutdown
            ],
       do: reason

  defp diagnostic_reason(_), do: :redacted

  @doc "Clear only ephemeral attempts during policy activation; retain credentials. Returns count."
  def invalidate_pending, do: call(:invalidate_pending)

  defp configured_callback do
    case NanoWeb.ApiGuard.callback_url() do
      {:ok, url} -> url
      _ -> nil
    end
  end

  defp current(logins), do: Map.reject(logins, fn {_, l} -> l.expires_at <= now() end)
  defp now, do: System.system_time(:millisecond)
end
