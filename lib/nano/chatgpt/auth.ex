defmodule Nano.ChatGPT.Auth do
  @moduledoc """
  The one process that holds the node's ChatGPT subscription credentials. It runs the OAuth
  device-code login, keeps the tokens in `<STATE_DIR>/chatgpt_auth.json` (mode 0600, written
  atomically), reloads them at boot, refreshes them before they expire, and hands a valid
  access token to whoever asks. Refresh tokens rotate, so nothing else ever refreshes: a
  rotated token is on disk before the new access token is handed out.

  Endpoints, client id and request shapes follow the Codex CLI's login crate
  (openai/codex, codex-rs/login); see `Nano.ChatGPT` for the inference side.

  Its HTTP calls run inside the process, which is what serialises refreshes; callers of
  `token/0` wait for one in progress. `status/0` never calls the process: the status is
  published to `:persistent_term` whenever it changes, so the dashboard can read it every
  second even while a request is in flight.
  """
  use GenServer
  require Logger

  # From codex-rs/login: the Codex CLI's public OAuth client.
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  # How long a device code may wait for approval, as the Codex CLI does.
  @login_ms 15 * 60_000
  # Refresh when the access token has less than this left, as codex does; a timer does it then.
  @margin_s 300
  @status_key {__MODULE__, :status}

  ## API

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The public status (see `Nano.Ops.chatgpt/0`); never the tokens."
  def status,
    do: :persistent_term.get(@status_key, public(%{tokens: nil, login: nil, error: nil}))

  @doc "Starts a device-code login: the pending status, or `{:error, message}`."
  def login, do: call(:login, 30_000)

  @doc "Forgets the tokens and any pending login. `:ok`."
  def logout, do: call(:logout, 30_000)

  @doc """
  `{:ok, %{access_token, account_id}}`, refreshed first if it is near expiry, or
  `{:error, message}`. Never log the result.
  """
  def token, do: call(:token, 60_000)

  @doc """
  Refreshes now, unless the access token has changed since `stale` was handed out (another
  caller already got it refreshed). For a request the backend refused with 401. Returns as `token/0`.
  """
  def refresh(stale), do: call({:refresh, stale}, 60_000)

  defp call(msg, timeout) do
    GenServer.call(__MODULE__, msg, timeout)
  catch
    :exit, reason ->
      {:error, "the ChatGPT credentials process did not answer (#{inspect(reason, limit: 5)})"}
  end

  ## Server

  @impl true
  # Cannot fail, so neither can the node's boot: anything wrong comes up as "not connected".
  def init(nil) do
    # A login that was pending when the process stopped is gone with it: its code is unknown now.
    s = %{tokens: nil, login: nil, error: nil, timer: nil}

    tokens =
      try do
        with {:ok, json} <- File.read(path()),
             {:ok, %{"access_token" => _, "refresh_token" => _} = tokens} <- Jason.decode(json) do
          tokens
        else
          {:error, :enoent} -> nil
          # Not the content: it may hold tokens.
          _ -> raise "not a token file"
        end
      rescue
        e ->
          Logger.error("Nano.ChatGPT.Auth: ignoring the token file: #{Exception.message(e)}")
          nil
      end

    {:ok, publish(schedule(%{s | tokens: tokens}))}
  end

  @impl true
  # Crash reports and :sys.get_status print the state: never the tokens.
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{tokens: %{}} = s -> %{s | tokens: :redacted}
      s -> s
    end)
  end

  @impl true
  def handle_call(:login, _from, %{login: %{}} = s), do: {:reply, public(s), s}

  def handle_call(:login, _from, s) do
    case post(auth_url() <> "/api/accounts/deviceauth/usercode", json: %{client_id: @client_id}) do
      {:ok, 200, %{"device_auth_id" => id} = body} ->
        code = body["user_code"] || body["usercode"]

        login = %{
          id: id,
          code: code,
          ref: make_ref(),
          interval: interval(body["interval"]),
          expires_at: System.system_time(:millisecond) + @login_ms
        }

        s = publish(%{s | login: login, error: nil})
        # The first poll at once, then one every interval, as codex polls.
        send(self(), {:poll, login.ref})
        {:reply, public(s), s}

      {:ok, 404, _} ->
        fail(s, "the server does not offer device-code login (HTTP 404)")

      other ->
        fail(s, "could not get a login code: #{why(other)}")
    end
  end

  def handle_call(:logout, _from, s) do
    File.rm(path())
    {:reply, :ok, publish(schedule(%{s | tokens: nil, login: nil, error: nil}))}
  end

  def handle_call(:token, _from, %{tokens: nil} = s),
    do: {:reply, {:error, "no ChatGPT subscription is connected to this node"}, s}

  def handle_call(:token, _from, s) do
    s = if expires_in(s.tokens) < @margin_s, do: do_refresh(s), else: s
    {:reply, credentials(s), s}
  end

  def handle_call({:refresh, stale}, _from, %{tokens: %{"access_token" => stale}} = s) do
    s = do_refresh(s)
    {:reply, credentials(s), s}
  end

  def handle_call({:refresh, _}, _from, s), do: {:reply, credentials(s), s}

  # Anyone may call or cast this process anything (an agent's eval, say); what it does not
  # know is refused or ignored, never a crash that would lose a login in progress.
  def handle_call(_msg, _from, s), do: {:reply, {:error, :unknown_call}, s}

  @impl true
  def handle_cast(_msg, s), do: {:noreply, s}

  # Codex's device flow: the user code is polled until approved, then exchanged with PKCE.
  @impl true
  def handle_info({:poll, ref}, %{login: %{ref: ref} = login} = s) do
    body = %{device_auth_id: login.id, user_code: login.code}

    cond do
      System.system_time(:millisecond) > login.expires_at ->
        {:noreply,
         publish(%{s | login: nil, error: "the login code expired before it was approved"})}

      true ->
        case post(auth_url() <> "/api/accounts/deviceauth/token", json: body) do
          {:ok, 200, %{"authorization_code" => code, "code_verifier" => verifier}} ->
            {:noreply, exchange(%{s | login: nil}, code, verifier)}

          # Not approved yet: codex waits on 403 and 404; pi also on these codes.
          {:ok, status, body} = refused when status in 400..499 ->
            cond do
              code(body) == "slow_down" ->
                login = %{login | interval: login.interval + 5_000}
                poll_later(login)
                {:noreply, %{s | login: login}}

              status in [403, 404] or code(body) == "deviceauth_authorization_pending" ->
                poll_later(login)
                {:noreply, s}

              true ->
                error = "the login was refused: #{why(refused)}"
                {:noreply, publish(%{s | login: nil, error: error})}
            end

          # Network trouble or a server error: keep polling until the code expires.
          _ ->
            poll_later(login)
            {:noreply, s}
        end
    end
  end

  def handle_info(:refresh, %{tokens: %{}} = s), do: {:noreply, do_refresh(s)}

  # A stale poll or timer is ignored like anything else sent here.
  def handle_info(_msg, s), do: {:noreply, s}

  defp fail(s, message), do: {:reply, {:error, message}, publish(%{s | error: message})}

  defp exchange(s, code, verifier) do
    form = [
      grant_type: "authorization_code",
      code: code,
      redirect_uri: auth_url() <> "/deviceauth/callback",
      client_id: @client_id,
      code_verifier: verifier
    ]

    case post(auth_url() <> "/oauth/token", form: form) do
      {:ok, 200, %{"access_token" => _, "refresh_token" => _} = body} ->
        store(s, body)

      other ->
        publish(%{
          s
          | error: "the approved login could not be exchanged for tokens: #{why(other)}"
        })
    end
  end

  defp do_refresh(s) do
    body = %{
      client_id: @client_id,
      grant_type: "refresh_token",
      refresh_token: s.tokens["refresh_token"]
    }

    result = post(auth_url() <> "/oauth/token", json: body)

    case if(permanent?(result), do: :permanent, else: result) do
      {:ok, 200, %{"access_token" => _} = new} ->
        store(s, new)

      # The refresh token is expired, revoked or already used: only a new login helps.
      :permanent ->
        Logger.warning("Nano.ChatGPT.Auth: refresh refused (#{why(result)}); signing out")
        File.rm(path())

        publish(
          schedule(%{
            s
            | tokens: nil,
              error:
                "the ChatGPT sign-in has expired or was revoked (#{why(result)}); connect again"
          })
        )

      # Transient: keep the tokens (the access token may still be good) and try again soon.
      other ->
        Logger.warning("Nano.ChatGPT.Auth: refresh failed: #{why(other)}")
        timer = Process.send_after(self(), :refresh, 60_000)
        cancel(s.timer)
        publish(%{s | timer: timer, error: "could not refresh the ChatGPT token: #{why(other)}"})
    end
  end

  # As codex decides (codex-rs/login/src/auth/manager.rs): a 401, invalid_grant, or the refresh
  # token expired, reused or invalidated. Anything else may pass.
  defp permanent?({:ok, 200, _}), do: false
  defp permanent?({:ok, 401, _}), do: true

  defp permanent?({:ok, _, body}),
    do:
      code(body) in ~w(invalid_grant refresh_token_expired refresh_token_reused refresh_token_invalidated)

  defp permanent?(_), do: false

  # New tokens (a refresh may omit what did not change) are written to disk before they are used.
  defp store(s, new) do
    claims = claims(new["id_token"] || s.tokens["id_token"])
    access = claims(new["access_token"])
    auth = claims["https://api.openai.com/auth"] || access["https://api.openai.com/auth"] || %{}

    tokens =
      Map.merge(s.tokens || %{}, Map.take(new, ~w(access_token refresh_token id_token)))
      |> Map.merge(%{
        "account_id" => auth["chatgpt_account_id"] || (s.tokens || %{})["account_id"],
        "plan" => auth["chatgpt_plan_type"] || (s.tokens || %{})["plan"],
        "email" => claims["email"] || get_in(access, ["https://api.openai.com/profile", "email"]),
        "expires_at" => access["exp"] || System.system_time(:second) + (new["expires_in"] || 3600)
      })

    case write(tokens) do
      :ok ->
        publish(schedule(%{s | tokens: tokens, error: nil}))

      {:error, reason} ->
        # Not saved, so not used: a rotated refresh token that only lived in memory would be
        # lost at the next restart.
        publish(%{
          s
          | error: "could not save the ChatGPT tokens to #{path()}: #{inspect(reason)}"
        })
    end
  end

  # Readable by its owner only, and never half-written: the content goes into a 0600 temp file
  # that then replaces the old one.
  defp write(tokens) do
    tmp = path() <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(tmp)),
         :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, Jason.encode!(tokens)) do
      File.rename(tmp, path())
    end
  end

  defp credentials(%{tokens: %{"access_token" => token, "account_id" => account}} = s) do
    if expires_in(s.tokens) > 0,
      do: {:ok, %{access_token: token, account_id: account}},
      else: {:error, s.error || "the ChatGPT access token has expired"}
  end

  defp credentials(s),
    do: {:error, s.error || "no ChatGPT subscription is connected to this node"}

  # A timer refreshes the token @margin_s before it expires, so it is fresh when an agent needs
  # it and the refresh token stays in use while the node is idle. Never sooner than a minute
  # (a short-lived token must not make it spin), nor later than Erlang timers allow.
  defp schedule(s) do
    cancel(s.timer)
    seconds = if s.tokens, do: (expires_in(s.tokens) - @margin_s) |> max(60) |> min(3_000_000)
    %{s | timer: seconds && Process.send_after(self(), :refresh, seconds * 1000)}
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp poll_later(login), do: Process.send_after(self(), {:poll, login.ref}, login.interval)

  defp expires_in(tokens), do: (tokens["expires_at"] || 0) - System.system_time(:second)

  defp interval(n) when is_integer(n), do: max(n, 1) * 1000

  defp interval(n) when is_binary(n),
    do: with({n, _} <- Integer.parse(n), do: interval(n), else: (_ -> interval(nil)))

  defp interval(_), do: 5_000

  # The status without anything secret, published for status/0.
  defp publish(s) do
    :persistent_term.put(@status_key, public(s))
    s
  end

  defp public(s) do
    t = s.tokens || %{}

    %{
      status:
        cond do
          s.login -> :pending
          s.tokens -> :connected
          true -> :disconnected
        end,
      user_code: s.login && s.login.code,
      verification_url: s.login && auth_url() <> "/codex/device",
      expires_at:
        cond do
          s.login -> DateTime.from_unix!(s.login.expires_at, :millisecond)
          t["expires_at"] -> DateTime.from_unix!(t["expires_at"])
          true -> nil
        end,
      email: t["email"],
      plan: t["plan"],
      error: s.error
    }
  end

  defp post(url, opts) do
    case Req.post(
           url,
           [retry: false, receive_timeout: 15_000, connect_options: [timeout: 10_000]] ++ opts
         ) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  # A JWT's claims, unverified: they come straight from the issuer over TLS.
  defp claims(jwt) when is_binary(jwt) do
    with [_, payload, _] <- String.split(jwt, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      claims
    else
      _ -> %{}
    end
  end

  defp claims(_), do: %{}

  # An OAuth error's code: `error` as a string, `error.code`, or `code`.
  defp code(%{"error" => code}) when is_binary(code), do: code
  defp code(%{"error" => %{"code" => code}}), do: code
  defp code(%{"code" => code}), do: code
  defp code(_), do: nil

  # Why a request failed, in words: the HTTP status and the error's code or message, never a
  # whole body (a 200 that lacked a field may still hold tokens).
  defp why({:ok, 200, _}), do: "HTTP 200 without the expected fields"

  defp why({:ok, status, body}) do
    case code(body) || (is_map(body) && body["error_description"]) do
      detail when is_binary(detail) -> "HTTP #{status}: #{String.slice(detail, 0, 200)}"
      _ -> "HTTP #{status}"
    end
  end

  defp why({:error, message}), do: message

  defp path, do: Path.join(Application.fetch_env!(:nano, :state_dir), "chatgpt_auth.json")
  defp auth_url, do: Nano.Settings.get(:chatgpt_auth_url)
end
