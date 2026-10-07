defmodule NanoWeb.StartForm do
  @moduledoc """
  The Start agent form: every option in view, prefilled with the node's defaults. The model
  box filters the model list (`Nano.Model.models/0`: the ChatGPT subscription's, when one is
  connected, then OpenRouter's) as you type, but takes any slug; the system prompt is one of
  default / file / custom, so only one can be sent. Under the model, the ChatGPT subscription
  control: connect (a device-code login), the code to enter while pending, then who is connected.
  `NanoWeb.ProcessLive` holds what was typed (so the once-a-second refresh keeps it) and
  calls `opts/1` and `error/1`.
  """
  use Phoenix.Component

  import NanoWeb.Components

  @limits [
    {"max_turns", "max turns", :agent_max_turns},
    {"max_tokens", "max tokens", :agent_max_tokens},
    {"max_context", "max context", :agent_max_context}
  ]

  attr :start, :map, required: true, doc: "what was typed so far"
  attr :models, :list, required: true
  attr :error, :any, required: true
  attr :chatgpt, :map, required: true, doc: "Nano.Ops.chatgpt/0"

  def start_form(assigns) do
    v = Map.merge(defaults(), assigns.start)
    assigns = assign(assigns, v: v, matches: matches(assigns.models, v["model"]))

    ~H"""
    <form id="start" class="start" phx-change="start_draft" phx-submit="start">
      <h2><.icon name="plus" /> Start agent</h2>
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
              if @models == [],
                do: "any OpenRouter slug",
                else: "type to filter #{length(@models)} models"
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
              {level}
            </option>
          </select>
        </label>
        <label class="field check">
          <input type="hidden" name="start_idle" value="false" />
          <input type="checkbox" name="start_idle" value="true" checked={@v["start_idle"] != "false"} />
          start idle
        </label>
      </div>
      <.chatgpt status={@chatgpt} />
      <div class="fields">
        <label :for={{field, label, _} <- limits()} class="field">
          {label}
          <input type="number" name={field} value={@v[field]} min="0" />
          <span class="hint">0 = no limit</span>
        </label>
      </div>
      <div class="field prompt">
        <span>system prompt</span>
        <div class="segmented" role="radiogroup">
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
        <button class="primary"><.icon name="play" /> Start</button>
        <p :if={@error} class="error">{@error}</p>
      </div>
    </form>
    """
  end

  attr :status, :map, required: true

  # Buttons of type "button", so they never submit the form around them.
  defp chatgpt(assigns) do
    ~H"""
    <div id="chatgpt" class="chatgpt">
      <span class="dim">ChatGPT subscription</span>
      <%= case @status.status do %>
        <% :connected -> %>
          <span>connected{if @status.email, do: " as #{@status.email}"}{if @status.plan,
            do: " (#{@status.plan})"} · models openai-codex/…</span>
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
          <button type="button" class="small" phx-click="chatgpt_login">Connect ChatGPT</button>
          <span class="dim">flat-rate models openai-codex/… on a Plus or Pro plan</span>
      <% end %>
      <span :if={@status.error} class="error">{@status.error}</span>
    </div>
    """
  end

  defp limits, do: @limits

  # What the form shows before anything is typed: the node's defaults, as values.
  defp defaults do
    limits =
      for {field, _, env} <- @limits,
          into: %{},
          do: {field, to_string(Application.get_env(:nano, env))}

    Map.merge(limits, %{
      "name" => "",
      "model" => Application.get_env(:nano, :default_model) || "",
      "reasoning" => Application.get_env(:nano, :reasoning, "off"),
      "start_idle" => "true",
      "prompt" => "default"
    })
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

  @doc "`NanoAgent.start/1` options from the submitted form. Only the chosen prompt is sent."
  def opts(params) do
    prompt = params["prompt"]

    [
      model: blank_to_nil(params["model"]),
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
    do: "openai-codex/ models need a ChatGPT subscription: connect one above"

  def error(:missing_model), do: "no model given and DEFAULT_MODEL is not set"

  def error(:invalid_option),
    do: "max turns, max tokens and max context must be whole numbers, 0 or more (0 = no limit)"

  def error(reason), do: refusal(reason)
end
