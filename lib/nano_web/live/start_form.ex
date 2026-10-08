defmodule NanoWeb.StartForm do
  @moduledoc """
  The Start agent form: every option in view and prefilled, all of it sent, since an agent
  has no defaults (`NanoAgent.start/1`). A provider is chosen first, from every provider the
  node supports (`Nano.Ops.providers/0`), each shown with its state; the first connected one
  is chosen until another is. Under the picker sits the chosen provider's connection: who is
  connected, with disconnect, or the ways to connect. OpenRouter connects with its OAuth flow
  (Connect OpenRouter, `NanoWeb.OpenRouterController`) or a pasted key; the ChatGPT
  subscription with a device-code login, showing the code to enter while pending. Start waits
  for the chosen provider to be connected.

  The model box offers only that provider's models (`Nano.OpenRouter.models/0` or
  `Nano.ChatGPT.models/0`), filtering them as you type but taking any name; a ChatGPT model is
  shown without its `openai-codex/` prefix and sent with it. The reasoning select offers the
  chosen model's levels, if its provider lists it; whenever the model changes, the select is
  set to the model's default level and max context to its context window. Max turns and max
  tokens start at 0, no limit. The system prompt is one of default / file / custom, so only
  one can be sent. `NanoWeb.ProcessLive` holds what was typed (so the once-a-second refresh
  keeps it) and calls `draft/1`, `choose/2`, `opts/1` and `error/1`; what `NanoAgent.start/1`
  refuses is shown under the form.
  """
  use Phoenix.Component

  import NanoWeb.Components

  @limits [
    {"max_turns", "max turns"},
    {"max_tokens", "max tokens"},
    {"max_context", "max context"}
  ]

  # The fields a model sets when it is chosen.
  @set_by_model ~w(reasoning max_context)

  attr :start, :map, required: true, doc: "what was typed so far"
  attr :models, :map, required: true, doc: ~s|each provider's models, by "openrouter", "chatgpt"|
  attr :error, :any, required: true
  attr :providers, :list, required: true, doc: "Nano.Ops.providers/0"
  attr :chatgpt, :map, required: true, doc: "Nano.Ops.chatgpt/0"
  attr :openrouter_error, :string, default: nil, doc: "why OpenRouter could not be connected"

  def start_form(assigns) do
    v = Map.merge(defaults(), assigns.start)

    provider =
      Enum.find(assigns.providers, &(&1.id == v["provider"])) ||
        Enum.find(assigns.providers, &(&1.status == :connected)) || hd(assigns.providers)

    v = Map.put(v, "provider", provider.id)
    models = assigns.models[provider.id] || []
    v = Map.put_new(v, "model", default_model(provider.id, models))
    model = Enum.find(models, &(&1.id == v["model"]))

    # What the model sets, unless typed since it was chosen: its default reasoning level, and
    # its context window as max context.
    set = %{
      "reasoning" => (model && model.default_reasoning) || v["reasoning"],
      "max_context" => to_string((model && model.context_length) || v["max_context"])
    }

    v = Map.merge(v, Map.drop(set, Map.keys(assigns.start)))

    assigns =
      assign(assigns,
        v: v,
        provider: provider,
        models: models,
        levels:
          case model do
            %{reasoning_levels: [_ | _] = levels} -> levels
            _ -> reasoning_levels()
          end,
        window: model && model.context_length,
        matches: matches(models, v["model"]),
        blocked: provider.status != :connected
      )

    ~H"""
    <section id="start-agent" class="start">
      <h2><.icon name="plus" /> Start agent</h2>
      <div class="field">
        <span>provider</span>
        <div id="providers" class="providers" role="radiogroup" aria-label="provider">
          <button
            :for={p <- @providers}
            type="button"
            role="radio"
            aria-checked={to_string(p.id == @provider.id)}
            class={["provider", p.status, p.id == @provider.id && "on"]}
            phx-click="pick_provider"
            phx-value-provider={p.id}
          >
            <span class="dot"></span>{p.name}<span class="state">{state(p.status)}</span>
          </button>
        </div>
      </div>
      <.openrouter :if={@provider.id == "openrouter"} provider={@provider} error={@openrouter_error} />
      <.chatgpt :if={@provider.id == "chatgpt"} status={@chatgpt} />
      <form id="start" phx-change="start_draft" phx-submit="start">
        <input type="hidden" name="provider" value={@provider.id} />
        <div class="fields">
          <label class="field">
            name <input type="text" name="name" value={@v["name"]} required autocomplete="off" />
          </label>
          <div class="field model">
            <label for="start-model">model</label>
            <input
              id="start-model"
              type="text"
              name="model"
              value={@v["model"]}
              autocomplete="off"
              phx-debounce="150"
              placeholder={
                cond do
                  @models != [] -> "type to filter #{length(@models)} models"
                  @provider.id == "openrouter" and not @blocked -> "any OpenRouter slug"
                  true -> "listed once connected"
                end
              }
            />
            <ul :if={@matches != []} class="matches">
              <li :for={m <- @matches}>
                <button type="button" phx-click="pick_model" phx-value-id={m.id}>
                  <span class="id">{m.id}</span>
                  <span class="dim">{txt(m.name)}{if m.context_length,
                    do: " · #{int(m.context_length)} context"}</span>
                </button>
              </li>
            </ul>
          </div>
          <label class="field">
            reasoning
            <select name="reasoning">
              <option :for={level <- @levels} value={level} selected={level == @v["reasoning"]}>
                {level}
              </option>
            </select>
          </label>
        </div>
        <div class="fields">
          <label :for={{field, label} <- limits()} class="field">
            {label}
            <input type="number" name={field} value={@v[field]} min="0" />
            <span class="hint">
              {cond do
                field != "max_context" -> "0 = no limit"
                @window -> "at most #{int(@window)}, the model's window"
                true -> "at most the model's window"
              end}
            </span>
          </label>
        </div>
        <div class="field prompt">
          <span>system prompt</span>
          <div class="segmented" role="radiogroup" aria-label="system prompt">
            <label
              :for={
                {choice, label} <- [{"default", "default"}, {"file", "file"}, {"custom", "custom"}]
              }
              class={@v["prompt"] == choice && "on"}
            >
              <input type="radio" name="prompt" value={choice} checked={@v["prompt"] == choice} />
              {label}
            </label>
          </div>
          <span :if={@v["prompt"] == "default"} class="dim">
            the node's template, {Nano.Settings.get(:system_prompt_file)}
          </span>
          <input
            :if={@v["prompt"] == "file"}
            type="text"
            name="system_prompt_file"
            value={@v["system_prompt_file"]}
            placeholder="a template file, relative to the app directory"
            autocomplete="off"
          />
          <textarea
            :if={@v["prompt"] == "custom"}
            name="system_prompt"
            rows="5"
            placeholder="the template itself; same {{placeholders}} as the default"
          >{@v["system_prompt"]}</textarea>
        </div>
        <div class="actions">
          <button class="primary" disabled={@blocked}><.icon name="play" /> Start</button>
          <label class="check">
            <input type="hidden" name="start_idle" value="false" />
            <input
              type="checkbox"
              name="start_idle"
              value="true"
              checked={@v["start_idle"] != "false"}
            /> start idle
          </label>
          <span :if={@blocked} class="dim">
            connect {if @provider.id == "chatgpt",
              do: "the ChatGPT subscription",
              else: "OpenRouter"} first
          </span>
          <p :if={@error} class="error">{@error}</p>
        </div>
      </form>
    </section>
    """
  end

  defp state(:connected), do: "connected"
  defp state(:pending), do: "connecting"
  defp state(_), do: "not connected"

  attr :provider, :map, required: true
  attr :error, :string, required: true

  # Outside the start form, so a pasted key is never among what it holds and renders back.
  defp openrouter(assigns) do
    ~H"""
    <div id="openrouter" class={["connection", @provider.status]}>
      <span class="dim">OpenRouter</span>
      <%= if @provider.status == :connected do %>
        <span>connected{if @provider.detail, do: " #{@provider.detail}"}</span>
        <button
          type="button"
          class="small"
          phx-click="openrouter_logout"
          data-confirm="Remove this node's OpenRouter key? Agents on OpenRouter models halt until a key is set again. The key itself stays valid at OpenRouter until you delete it there."
        >
          disconnect
        </button>
      <% else %>
        <span>not connected</span>
        <a class="button small" href="/openrouter/connect">Connect OpenRouter</a>
        <form id="openrouter-key" phx-submit="openrouter_key">
          <input
            type="password"
            name="key"
            placeholder="or paste an API key"
            aria-label="OpenRouter API key"
            autocomplete="off"
          />
          <button class="small">save</button>
        </form>
        <span class="dim">every agent can read the key: keep its spending limit low</span>
      <% end %>
      <span :if={@error} class="error">{@error}</span>
    </div>
    """
  end

  attr :status, :map, required: true

  # Buttons of type "button", so they never submit a form around them.
  defp chatgpt(assigns) do
    ~H"""
    <div id="chatgpt" class={["connection", @status.status]}>
      <span class="dim">ChatGPT subscription</span>
      <%= case @status.status do %>
        <% :connected -> %>
          <span>connected{if @status.email, do: " as #{@status.email}"}{if @status.plan,
            do: " (#{@status.plan})"}</span>
          <button
            type="button"
            class="small"
            phx-click="chatgpt_logout"
            data-confirm="Forget this node's ChatGPT tokens? Agents on openai-codex/ models will fail until you connect again."
          >
            disconnect
          </button>
        <% :pending -> %>
          <span>
            open <a href={@status.verification_url} target="_blank" rel="noopener">{@status.verification_url}</a>, sign in, and enter
            <code class="user-code">{@status.user_code}</code>
          </span>
          <span class="dim">waiting for approval · expires {time(@status.expires_at)} UTC</span>
          <button type="button" class="small" phx-click="chatgpt_logout">cancel</button>
        <% _ -> %>
          <span>not connected</span>
          <button type="button" class="small" phx-click="chatgpt_login">Connect ChatGPT</button>
          <span class="dim">flat-rate on a Plus or Pro plan</span>
      <% end %>
      <span :if={@status.error} class="error">{@status.error}</span>
    </div>
    """
  end

  defp limits, do: @limits

  # What the form shows before anything is typed. The model is `default_model/2`'s, for the
  # provider chosen; the model then sets the reasoning level and max context.
  defp defaults do
    %{
      "name" => "",
      "max_turns" => "0",
      "max_tokens" => "0",
      "max_context" => "",
      "start_idle" => "true",
      "prompt" => "default"
    }
  end

  # For ChatGPT, the first model the subscription lists (the catalog's highest priority); for
  # OpenRouter none, since it lists hundreds.
  defp default_model("chatgpt", [first | _]), do: first.id
  defp default_model(_, _), do: ""

  @doc "What was typed, less the model and what it sets: the form shows the provider's default."
  def unchosen(params), do: Map.drop(params, ["model" | @set_by_model])

  @doc """
  What was typed, with `provider` chosen and the model emptied, so the box shows that
  provider's default and the form that model's settings.
  """
  def choose(start, provider), do: start |> unchosen() |> Map.put("provider", provider)

  @doc """
  What was typed, as the form keeps it. Choosing a model empties its reasoning level and max
  context, so the form shows that model's. A whole slug of the other provider's chooses it: an
  `openai-codex/` slug ChatGPT, leaving the model's name in the box; while ChatGPT is chosen,
  a slug with a `/` OpenRouter, since ChatGPT's model names have none.
  """
  def draft(%{"_target" => ["model"]} = params),
    do: params |> Map.drop(["_target" | @set_by_model]) |> draft()

  def draft(params) do
    case Nano.Model.split(String.trim(params["model"] || "")) do
      {:chatgpt, model} ->
        Map.merge(params, %{"provider" => "chatgpt", "model" => model})

      {:openrouter, slug} ->
        if params["provider"] == "chatgpt" and String.contains?(slug, "/"),
          do: Map.merge(params, %{"provider" => "openrouter", "model" => slug}),
          else: params
    end
  end

  @doc """
  Up to 8 models matching what was typed: ids or names containing it first, then those
  containing its letters in order (a fuzzy match). None once it names a model exactly.
  """
  def matches(models, query) do
    q = String.downcase(String.trim(query || ""))

    if q == "" or Enum.any?(models, &(&1.id == query)) do
      []
    else
      for m <- models,
          text = String.downcase("#{m.id} #{m.name}"),
          rank = rank(text, q),
          do: {rank, m}
    end
    |> Enum.sort_by(fn {rank, m} -> {rank, String.length(m.id)} end)
    |> Enum.take(8)
    |> Enum.map(&elem(&1, 1))
  end

  defp rank(text, q) do
    case :binary.match(text, q) do
      {pos, _} -> pos
      :nomatch -> if in_order?(q, text), do: 10_000
    end
  end

  defp in_order?(<<>>, _), do: true

  defp in_order?(<<c::utf8, rest::binary>>, text) do
    case :binary.match(text, <<c::utf8>>) do
      {pos, len} -> in_order?(rest, binary_part(text, pos + len, byte_size(text) - pos - len))
      :nomatch -> false
    end
  end

  @doc """
  `NanoAgent.start/1` options from the submitted form. Only the chosen prompt is sent, and the
  model as a slug: `openai-codex/` and the name for ChatGPT.
  """
  def opts(params) do
    params = draft(params)
    prompt = params["prompt"]

    model =
      case {params["provider"], blank_to_nil(params["model"])} do
        {"chatgpt", model} when model != nil -> Nano.Model.slug(:chatgpt, model)
        {_, model} -> model
      end

    [
      model: model,
      start_idle: params["start_idle"] != "false",
      max_turns: number(params["max_turns"]),
      max_tokens: number(params["max_tokens"]),
      max_context: number(params["max_context"]),
      reasoning: params["reasoning"],
      system_prompt: if(prompt == "custom", do: blank_to_nil(params["system_prompt"])),
      system_prompt_file: if(prompt == "file", do: blank_to_nil(params["system_prompt_file"]))
    ]
    |> Enum.reject(fn {_, v} -> v == nil end)
  end

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      value -> value
    end
  end

  # A whole number as an integer; anything else typed is passed on as typed, for
  # `NanoAgent.start/1` to reject as it would from the API. Blank is missing.
  defp number(value) do
    value = blank_to_nil(value)

    case value && Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  @doc "Why the agent could not be started, in words: `NanoAgent.start/1`'s message."
  def error({:already_started, _}), do: "an agent with that name is already running"
  def error(message) when is_binary(message), do: message
  def error(reason), do: inspect(reason)
end
