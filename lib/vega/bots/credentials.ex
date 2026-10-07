defmodule Vega.Bots.Credentials do
  @moduledoc """
  Credential-specific human conduit. `request_setting/4` stores only setting name and
  question; `answer_setting/3` accepts the secret solely in the caller/HTTP process,
  writes through Nano.Ops, then sends the Bots service only non-secret metadata.
  Never call this with a real credential through an agent eval: eval source/results
  are logged. Use the consumer password control's direct JSON POST instead.
  """
  def key(name) do
    case Nano.Settings.key(name) do
      {:ok, registered} when is_atom(registered) ->
        if Enum.any?(Nano.Settings.specs(), &(&1.key == registered and &1.type == :secret)),
          do: {:ok, Atom.to_string(registered)},
          else: {:error, :not_a_secret_setting}

      {:ok, custom} when is_binary(custom) ->
        if Regex.match?(~r/\A[A-Z_][A-Z0-9_]{0,99}\z/, custom),
          do: {:ok, custom},
          else: {:error, :uppercase_secret_name_required}

      _ ->
        {:error, :invalid_setting_name}
    end
  end

  def request_setting(bot, name, question, opts \\ []) do
    with {:ok, canonical} <- key(name) do
      Vega.Bots.request_human(
        bot,
        question,
        opts |> Keyword.put(:kind, "setting") |> Keyword.put(:setting_key, canonical)
      )
    end
  end

  def answer_setting(id, password, opts \\ [])

  def answer_setting(id, password, opts)
      when is_binary(password) and byte_size(password) in 1..16_000 do
    server = Keyword.get(opts, :server, Vega.Bots.Server)

    :global.trans(
      {{__MODULE__, server, id}, self()},
      fn ->
        with {:ok, request} <- Vega.Bots.get_request(id, opts),
             true <- request["kind"] == "setting",
             {:ok, canonical} <- key(request["setting_key"]) do
          if request["status"] == "answered" do
            {:ok, request["answer"]}
          else
            case Nano.Ops.put_setting(canonical, password) do
              :ok ->
                case GenServer.call(server, {:setting_answer, id, canonical}, 10_000) do
                  {:ok, completed} -> {:ok, completed["answer"]}
                  _ -> {:error, :confirmation_failed}
                end

              _ ->
                {:error, :setting_not_saved}
            end
          end
        else
          false -> {:error, :not_a_setting_request}
          {:error, _} -> {:error, :invalid_setting_request}
        end
      end,
      [node()]
    )
  rescue
    _ -> {:error, :setting_not_saved}
  catch
    _, _ -> {:error, :setting_not_saved}
  end

  def answer_setting(_, _, _), do: {:error, :invalid_credential}
end
