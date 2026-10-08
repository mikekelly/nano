defmodule Seedling.FrontOfMind.Drift do
  @moduledoc """
  Optional Jev drift adapter. Uses one typed Noul judgement, with bounded note and
  recent activity, never changes the note and never sends the entire conversation.
  `judge/3` returns `{:ok, %{probability: number, model: string, usage: map}}`
  or an honest error. Missing `TYPESAFE_API_KEY` makes **no network request**.

  Options: `api_key`, `url`, `model`, `timeout` (default 3 seconds), `transport`
  (an injected one-argument request function for tests). No retries, no spending
  unless drift is explicitly enabled in `Seedling.FrontOfMind.configure/3`.
  A Noul probability is a model estimate, not evidence that drift is wrong.
  """
  @doc "Checks whether recent activity has diverged from the agent's stated note."
  def judge(note, activity, opts \\ []) do
    key =
      if Keyword.has_key?(opts, :api_key),
        do: opts[:api_key],
        else: Nano.Settings.get("TYPESAFE_API_KEY")

    if key in [nil, ""] do
      {:error, :missing_credentials}
    else
      request = [
        url: opts[:url] || "https://api.typesafe.ai/v1/systemone",
        headers: [{"authorization", "Bearer " <> key}],
        json: %{
          model: opts[:model] || "jev-latest",
          state:
            "Agent's own note:\n#{String.slice(note, 0, 1_000)}\nRecent activity:\n#{String.slice(activity, 0, 2_000)}",
          questions: %{
            drift: %{
              type: "noul",
              instructions:
                "Recent activity has diverged from the priorities or constraints in the agent's own note. Judge divergence, not whether changing course is justified."
            }
          }
        },
        receive_timeout: opts[:timeout] || 3_000,
        retry: false
      ]

      transport = opts[:transport] || (&Req.post/1)

      case transport.(request) do
        {:ok, %{status: 200, body: %{"answers" => %{"drift" => %{"noul" => p}}} = body}}
        when is_number(p) and p >= 0 and p <= 1 ->
          {:ok, %{probability: p, model: body["model"], usage: body["usage"] || %{}}}

        {:ok, %{status: status}} when status != 200 ->
          {:error, {:http_status, status}}

        {:ok, _} ->
          {:error, :invalid_response}

        {:error, _} ->
          {:error, :transport_failed}
      end
    end
  rescue
    _ -> {:error, :adapter_failed}
  end
end
