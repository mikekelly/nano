defmodule NanoWeb.StartForm do
  @moduledoc """
  The Start agent form: every option in view, prefilled with the node's defaults. A provider
  is chosen first, OpenRouter or the ChatGPT subscription, and the model box offers only that
  provider's models (`Nano.OpenRouter.models/0` or `Nano.ChatGPT.models/0`), filtering them as
  you type but taking any name; a ChatGPT model is shown without its `openai-codex/` prefix and
  sent with it. With ChatGPT chosen, its connection sits under the model: connect (a
  device-code login), the code to enter while pending, then who is connected; Start waits for
  it. The system prompt is one of default / file / custom, so only one can be sent.
  `NanoWeb.ProcessLive` holds what was typed (so the once-a-second refresh keeps it) and calls
  `draft/1`, `opts/1` and `error/1`.
  """
  use Phoenix.Component

  import NanoWeb.Components

  @limits [
    {"max_turns", "max turns", :agent_max_turns},
    {"max_tokens", "max tokens", :agent_max_tokens},
    {"max_context", "max context", :agent_max_context}
  ]

  attr :start, :map, required: true, doc: "what was typed so far"
  attr :models, :map, required: true, doc: ~s|each provider's models, by "openrouter", "chatgpt"|
  attr :error, :any, required: true
  attr :chatgpt, :map, required: true, doc: "Nano.Ops.chatgpt/0"

  def start_form(assigns) do
    v = Map.merge(defaults(), assigns.start)
    chatgpt? = v["provider"] == "chatgpt"
    models = assigns.models[v["provider"]] || []
    v = Map.put_new(v, "model", default_model(v["provider"], models))

    assigns =
      assign(assigns,
        v: v,
        chatgpt?: chatgpt?,
        models: models,
        matches: matches(models, v["model"]),
        blocked: chatgpt? and assigns.chatgpt.status != :connected
      )

    ~H"""
    <form id="start" class="start" phx-change="start_draft" phx-submit="start">
      <h2><.icon name="plus" /> Start agent</h2>
      <div class="fields">
        <label class="field">
          name <input type="text" name="name" value={@v["name"]} required autocomplete="off" />
        </label>
        <div class="field">
          <span>provider</span>
          <div class="segmented" role="radiogroup" aria-label="provider">
            <label
              :for={{choice, label} <- [{"openrouter", "OpenRouter"}, {"chatgpt", "ChatGPT"}]}
              class={@v["provider"] == choice && "on"}
            >
              <input type="radio" name="provider" value={choice} checked={@v["provider"] == choice} />
              {label}
            </label>
          </div>
        </div>
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
                @chatgpt? -> "listed once connected"
                true -> "any OpenRouter slug"
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
            <option
              :for={level <- reasoning_levels()}
              value={level}
              selected={level == @v["reasoning"]}
            >
              {level}{if @chatgpt? and level == "minimal", do: " (= low)"}
            </option>
          </select>
        </label>
      </div>
      <.chatgpt :if={@chatgpt?} status={@chatgpt} />
      <div class="fields">
        <label :for={{field, label, _} <- limits()} class="field">
          {label}
          <input type="number" name={field} value={@v[field]} min="0" />
          <span class="hint">0 = no limit</span>
        </label>
      </div>
      <div class="field prompt">
        <span>system prompt</span>
        <div class="segmented" role="radiogroup" aria-label="system prompt">
          <label
            :for={{choice, label} <- [{"default", "default"}, {"file", "file"}, {"custom", "custom"}]}
            class={@v["prompt"] == choice && "on"}
          >
            <input type="radio" name="prompt" value={choice} checked={@v["prompt"] == choice} />
            {label}
          </label>
        </div>
        <span :if={@v["prompt"] == "default"} class="dim">
          the node's template, {Application.get_env(:nano, :system_prompt_file)}
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
          <input type="checkbox" name="start_idle" value="true" checked={@v["start_idle"] != "false"} />
          start idle
        </label>
        <span :if={@blocked} class="dim">connect the ChatGPT subscription first</span>
        <p :if={@error} class="error">{@error}</p>
      </div>
    </form>
    """
  end

  attr :status, :map, required: true

  # Buttons of type "button", so they never submit the form around them.
  defp chatgpt(assigns) do
    ~H"""
    <div id="chatgpt" class={["chatgpt", @status.status]}>
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

  # What the form shows before anything is typed: the node's defaults, as values. The model is
  # `default_model/2`'s, for the provider chosen.
  defp defaults do
    limits =
      for {field, _, env} <- @limits,
          into: %{},
          do: {field, to_string(Application.get_env(:nano, env))}

    {provider, _} = Nano.Model.split(Application.get_env(:nano, :default_model) || "")

    Map.merge(limits, %{
      "name" => "",
      "provider" => Atom.to_string(provider),
      "reasoning" => Application.get_env(:nano, :reasoning, "off"),
      "start_idle" => "true",
      "prompt" => "default"
    })
  end

  # DEFAULT_MODEL, if it is this provider's; else, for ChatGPT, the first model the
  # subscription lists (the catalog's highest priority).
  defp default_model(provider, models) do
    {default, model} = Nano.Model.split(Application.get_env(:nano, :default_model) || "")

    cond do
      provider == Atom.to_string(default) -> model
      provider == "chatgpt" and models != [] -> hd(models).id
      true -> ""
    end
  end

  @doc """
  What was typed, as the form keeps it. Choosing a provider empties the model, so the box
  shows that provider's default. A whole slug of the other provider's chooses it: an
  `openai-codex/` slug ChatGPT, leaving the model's name in the box; while ChatGPT is chosen,
  a slug with a `/` OpenRouter, since ChatGPT's model names have none.
  """
  def draft(%{"_target" => ["provider"]} = params), do: Map.delete(params, "model")

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
        # None, rather than OpenRouter's default.
        {"chatgpt", nil} -> ""
        {"chatgpt", model} -> Nano.Model.slug(:chatgpt, model)
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
  # `NanoAgent.start/1` to reject as it would from the API. Blank means the default.
  defp number(value) do
    value = blank_to_nil(value)

    case value && Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  @doc "Why the agent could not be started, in words."
  def error(:invalid_name), do: "name must be letters, digits, _ . or -"
  def error({:already_started, _}), do: "an agent with that name is already running"
  def error(:missing_openrouter_api_key), do: "OPENROUTER_API_KEY is not set on this node"

  def error(:chatgpt_not_connected),
    do: "the ChatGPT subscription is not connected: connect it above"

  def error(:missing_model), do: "choose a model"

  def error(:invalid_option),
    do: "max turns, max tokens and max context must be whole numbers, 0 or more (0 = no limit)"

  def error(reason), do: refusal(reason)
end
