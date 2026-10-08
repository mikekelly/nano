defmodule Nano.Settings do
  @moduledoc """
  The node's settings, owned by this one process. The seed's own (`specs/0`): its provider's
  key and the providers' addresses, the node-wide limits, what new agents' system prompts
  state, and the recording of model requests (`Nano.RawLog`), each with a default. Besides those, operators may supply values of their own, under
  names of their choosing (`"SOME_SERVICE_KEY"`): opaque strings the seed never reads, kept and
  shown like a key. What is set is kept in `<STATE_DIR>/settings.json` (mode 0600, written
  atomically), loaded at boot, and changed while the node runs, through
  `Nano.Ops.put_setting/2` and `Nano.Ops.delete_setting/1`: no restart, and nothing in the
  node's environment.

  `get/1` never calls the process: the values are published to `:persistent_term` whenever
  they change, so reading a setting is cheap enough for every request. The process cannot
  fail to start: a missing or unreadable file comes up with the defaults.

  Keys and the operators' own values are secrets: never logged, never in crash reports
  (`format_status/1`), never in `public/0`. Agents run as root, so any of them can still read
  one, with `get/1` or from the file.
  """
  use GenServer
  require Logger

  @values {__MODULE__, :values}

  # {key, default, type, when a change takes effect, what it is}. `:agent_start`: the system
  # prompt states it, so each agent keeps the value it started with (NanoAgent).
  @specs [
    {:openrouter_api_key, nil, :secret, :live,
     "OpenRouter's API key. Without it OpenRouter is off: its models are refused, and agents " <>
       "on them are halted (provider_unavailable). Every agent can read it: use a dedicated " <>
       "key with a low spending limit"},
    {:node_max_tokens_per_hour, 100_000_000, {:integer, 0, nil}, :live,
     "Tokens all agents together may use in an hour; an agent about to call the model past " <>
       "it is halted (node_budget). 0 = no limit"},
    {:eval_timeout_ms, 30_000, {:integer, 1, 4_294_967_295}, :live,
     "How long an eval may run before it is killed, in milliseconds"},
    {:model_call_max_ms, 1_800_000, {:integer, 1, 4_294_967_295}, :live,
     "How long one model request may take, in milliseconds, from sending it to the end of " <>
       "its reply, however steadily the reply arrives: past it the request is cancelled and " <>
       "fails as a transient error, retried as any other. It caps one reply, not a " <>
       "connection; requests sent after a change use the new value"},
    {:result_max_bytes, 51_200, {:integer, 1, 8_388_608}, :agent_start,
     "Where tool results and events are cut, in bytes; the whole text goes to a spill file"},
    {:max_bindings_bytes, 16_000_000, {:integer, 0, nil}, :live,
     "Eval variables are saved for restarts up to this many bytes in total; larger ones stay " <>
       "bound in the running process only"},
    {:network_policy, "unrestricted outbound internet access", :text, :agent_start,
     "The network access agents are told they have; must be true of the container's network"},
    {:system_prompt_file, "prompts/seed.txt", :file, :agent_start,
     "The default system prompt template, relative to the app directory; read at each agent " <>
       "start and restart"},
    {:openrouter_base_url, "https://openrouter.ai/api/v1", :url, :live, "OpenRouter's API"},
    {:chatgpt_base_url, "https://chatgpt.com/backend-api/codex", :url, :live,
     "The Codex backend that serves openai-codex/ models"},
    {:chatgpt_auth_url, "https://auth.openai.com", :url, :live,
     "The OAuth server for the ChatGPT device-code login and token refresh"},
    {:chatgpt_client_version, "0.160.1", :version, :live,
     "The Codex CLI version reported when listing models: the backend lists only the models " <>
       "released to clients at least this new, so keep it at Codex's latest release"},
    {:raw_model_log, "off", :agents, :live,
     "For debugging: off, all, or agent names separated by commas. Each model request of " <>
       "those agents, every attempt, is recorded byte for byte, as sent and as received " <>
       "(credentials redacted from the headers), in files under <LOG_DIR>/raw/<agent id>/ " <>
       "that their log entries link to. The files are large, and a request holds the " <>
       "agent's whole conversation, with anything sensitive it has seen"},
    {:raw_model_log_max_bytes, 1_000_000_000, {:integer, 1, nil}, :live,
     "The most raw_model_log keeps, in bytes, over all agents: past it, the oldest files " <>
       "are deleted as new ones are written"}
  ]

  @keys Enum.map(@specs, &elem(&1, 0))

  ## API

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Every setting: `%{key, default, type, applies, about}`, in a fixed order."
  def specs,
    do:
      for(
        {key, default, type, applies, about} <- @specs,
        do: %{key: key, default: default, type: type, applies: applies, about: about}
      )

  @doc """
  A setting's value, never calling the process: one of the seed's (an atom, or its name) as
  set or its default; an operator's own (by its name, in any case, as a string or an atom:
  `"TYPESAFE_API_KEY"`, `"typesafe_api_key"` and `:typesafe_api_key` are the same) as set,
  or nil.
  """
  def get(key) when key in @keys, do: Map.get(values(), key, default(key))

  def get(name) do
    case key(name) do
      {:ok, key} when is_atom(key) -> get(key)
      {:ok, name} -> Map.get(values(), name)
      {:error, _} -> nil
    end
  end

  @doc """
  Every setting as an operator may see it, the seed's in a fixed order, then the operators'
  own by name: `%{key, value, set, default, secret, applies, about}`, `set` being whether it
  was set (rather than left at its default). A secret's `value` is nil; `last4` is its last 4
  characters, when it is long enough to spare them.
  """
  def public do
    own =
      for name <- values() |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort(),
          do: %{
            key: name,
            default: nil,
            applies: :live,
            about: "Supplied by the operators, for whatever needs it; the seed never reads it"
          }

    for %{key: key} = spec <- Enum.map(specs(), &Map.delete(&1, :type)) ++ own do
      value = get(key)

      Map.merge(spec, %{
        set: Map.has_key?(values(), key),
        secret: secret?(key),
        value: if(not secret?(key), do: value),
        last4: if((secret?(key) and value) && String.length(value) >= 16, do: last4(value))
      })
    end
  end

  @doc """
  Sets a setting, saved before it is used: `:ok`, or `{:error, message}` saying what is
  allowed (or why it could not be saved). `key` is as for `key/1`; a whole number may come as
  text, as it does from a form or `.env`. An operator's own value is any string.
  """
  def put(key, value) do
    with {:ok, key} <- key(key),
         {:ok, value} <- check(key, value),
         do: call({:put, key, value})
  end

  @doc """
  Puts one of the seed's settings back to its default (a key: unset), or forgets one of the
  operators' own. `:ok`, or `{:error, message}`.
  """
  def delete(key) do
    with {:ok, key} <- key(key) do
      if is_binary(key) and not Map.has_key?(values(), key),
        do: {:error, "no setting #{key} is set"},
        else: call({:delete, key})
    end
  end

  @doc """
  A setting's key from its name: `{:ok, atom}` for one of the seed's, named in either case
  (`openrouter_api_key`, or `OPENROUTER_API_KEY` as in `.env`); `{:ok, name}` for any other
  name of letters, digits and `_` (an operator's own), upper-cased as in `.env`, and given
  as a string or an atom; else `{:error, message}`.
  """
  def key(key) when key in @keys, do: {:ok, key}

  def key(key) when is_atom(key) and key not in [nil, true, false],
    do: key(Atom.to_string(key))

  def key(name) when is_binary(name) do
    cond do
      key = Enum.find(@keys, &(Atom.to_string(&1) == String.downcase(name))) ->
        {:ok, key}

      name =~ ~r/^[A-Za-z_][A-Za-z0-9_]{0,99}$/ ->
        {:ok, String.upcase(name)}

      true ->
        {:error,
         "#{inspect(name)} is not a setting name: the node's own settings are " <>
           "#{Enum.join(@keys, ", ")}, and a value of the operators' own is named with " <>
           "letters, digits and _ (such as SOME_SERVICE_KEY)"}
    end
  end

  def key(other), do: {:error, "a setting is named by a string, not #{inspect(other)}"}

  defp values, do: :persistent_term.get(@values, %{})

  defp call(msg) do
    GenServer.call(__MODULE__, msg, 30_000)
  catch
    :exit, reason ->
      {:error, "the settings process did not answer (#{inspect(reason, limit: 5)})"}
  end

  defp default(key), do: elem(List.keyfind(@specs, key, 0), 1)
  # An operator's own value is an opaque secret.
  defp type(name) when is_binary(name), do: :own
  defp type(key), do: elem(List.keyfind(@specs, key, 0), 2)
  defp secret?(key), do: type(key) in [:secret, :own]
  defp last4(value), do: String.slice(value, -4, 4)

  ## Validation

  # {:ok, value} or {:error, message}. Messages never repeat the value: it may be a secret.
  defp check(key, value), do: check(key, type(key), value)

  defp check(name, :own, value) do
    if is_binary(value), do: {:ok, value}, else: {:error, "#{name} must be a string"}
  end

  defp check(key, :secret, value) do
    value = if is_binary(value), do: String.trim(value)

    if is_binary(value) and value =~ ~r/^\S+$/,
      do: {:ok, value},
      else:
        {:error,
         "#{key} must be a non-empty string without spaces (to remove the key, clear the setting)"}
  end

  defp check(key, {:integer, min, max}, value) do
    n =
      case value do
        n when is_integer(n) -> n
        text when is_binary(text) -> with {n, ""} <- Integer.parse(String.trim(text)), do: n
        _ -> nil
      end

    if is_integer(n) and n >= min and (max == nil or n <= max),
      do: {:ok, n},
      else:
        {:error,
         "#{key} must be a whole number " <>
           if(max, do: "from #{min} to #{max}", else: "of #{min} or more") <>
           if(min == 0, do: " (0 = no limit)", else: "")}
  end

  defp check(key, :text, value) do
    if is_binary(value) and String.trim(value) != "",
      do: {:ok, String.trim(value)},
      else: {:error, "#{key} must be non-empty text"}
  end

  defp check(key, :url, value) do
    value = if is_binary(value), do: value |> String.trim() |> String.trim_trailing("/")

    case value && URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, value}

      _ ->
        {:error, "#{key} must be an http:// or https:// URL"}
    end
  end

  defp check(key, :version, value) do
    if is_binary(value) and String.trim(value) =~ ~r/^\d+(\.\d+)+([-+][\w.-]+)?$/,
      do: {:ok, String.trim(value)},
      else: {:error, "#{key} must be a version number, such as 0.160.1"}
  end

  # "off", "all", or agent names (a list, or text separated by commas or spaces) as
  # "alice, bob".
  defp check(key, :agents, value) do
    names =
      case value do
        text when is_binary(text) -> String.split(text, [",", " "], trim: true)
        list when is_list(list) -> list
        _ -> [nil]
      end

    cond do
      names in [["off"], ["all"]] ->
        {:ok, hd(names)}

      names != [] and Enum.all?(names, &(is_binary(&1) and &1 =~ ~r/^[\w.-]+$/)) ->
        {:ok, names |> Enum.uniq() |> Enum.join(", ")}

      true ->
        {:error, "#{key} must be off, all, or agent names separated by commas"}
    end
  end

  # Only on a change: a file that has gone since is reported at the next start instead.
  defp check(key, :file, value) do
    with {:ok, path} <- check(key, :text, value) do
      case File.read(path) do
        {:ok, _} ->
          {:ok, path}

        {:error, e} ->
          {:error,
           "#{key} must be a readable file, relative to the app directory (#{File.cwd!()}) or " <>
             "absolute: cannot read #{path}: #{:file.format_error(e)}"}
      end
    end
  end

  ## Server

  @impl true
  # Cannot fail, so neither can the node's boot: anything wrong comes up as the defaults.
  def init(nil) do
    values =
      try do
        case File.read(path()) do
          {:error, :enoent} -> %{}
          {:ok, json} -> load(Jason.decode!(json))
          {:error, e} -> raise File.Error, reason: e, action: "read", path: path()
        end
      rescue
        # Not the content: it may hold keys.
        e ->
          Logger.error(
            "Nano.Settings: ignoring #{path()}, using the defaults: " <>
              if(is_exception(e, File.Error),
                do: Exception.message(e),
                else: "not a settings file"
              )
          )

          %{}
      end

    {:ok, publish(values)}
  end

  # Each value is checked as a change would be (a file setting only for its type), so a bad
  # one goes back to its default; the rest are kept.
  defp load(%{} = json) do
    for {name, value} <- json, reduce: %{} do
      values ->
        with {:ok, key} <- key(name),
             {:ok, value} <-
               if(type(key) == :file, do: check(key, :text, value), else: check(key, value)) do
          Map.put(values, key, value)
        else
          _ ->
            Logger.error(
              "Nano.Settings: ignoring #{inspect(name)} in #{path()}: not a valid setting"
            )

            values
        end
    end
  end

  @impl true
  def handle_call({:put, key, value}, _from, values),
    do: save(values, Map.put(values, key, value))

  def handle_call({:delete, key}, _from, values), do: save(values, Map.delete(values, key))
  def handle_call(_msg, _from, values), do: {:reply, {:error, :unknown_call}, values}

  # Anyone may send this process anything.
  @impl true
  def handle_info(_msg, values), do: {:noreply, values}

  @impl true
  def handle_cast(_msg, values), do: {:noreply, values}

  @impl true
  # Crash reports and :sys.get_status print the state and the last message: never a secret.
  def format_status(status) do
    status
    |> Map.update(:state, nil, &redact/1)
    |> Map.update(:message, nil, fn
      {:put, key, _} -> {:put, key, :redacted}
      message -> message
    end)
  end

  defp redact(%{} = values),
    do: Map.new(values, fn {k, v} -> {k, if(secret?(k), do: :redacted, else: v)} end)

  defp redact(other), do: other

  # Saved before it is used: a change that only lived in memory would be lost at a restart.
  defp save(old, old), do: {:reply, :ok, old}

  defp save(old, new) do
    case write(new) do
      :ok -> {:reply, :ok, publish(new)}
      {:error, reason} -> {:reply, {:error, "could not save #{path()}: #{inspect(reason)}"}, old}
    end
  end

  # Readable by its owner only, and never half-written: the content goes into a 0600 temp file
  # that then replaces the old one.
  defp write(values),
    do: SafetyNet.write_credential(path(), Jason.encode!(values, pretty: true))

  defp publish(values) do
    if :persistent_term.get(@values, nil) != values, do: :persistent_term.put(@values, values)
    values
  end

  defp path, do: Path.join(Application.fetch_env!(:nano, :state_dir), "settings.json")
end
