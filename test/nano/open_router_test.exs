defmodule Nano.OpenRouterTest do
  # Not async: the base URL and the model cache are node-wide.
  use ExUnit.Case, async: false

  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    :persistent_term.erase({Nano.OpenRouter, :models})
    on_exit(fn -> :persistent_term.erase({Nano.OpenRouter, :models}) end)
  end

  test "models/0 parses the list, sorted by id, and caches it" do
    Fake.models([
      %{
        "id" => "b/two",
        "name" => "Two",
        "context_length" => 1000,
        "pricing" => %{"prompt" => "0.000002", "completion" => "0"}
      },
      %{"id" => "a/one", "name" => "One", "context_length" => 2000, "pricing" => %{}}
    ])

    assert [
             %{
               id: "a/one",
               name: "One",
               context_length: 2000,
               prompt_price: nil,
               completion_price: nil
             },
             %{
               id: "b/two",
               name: "Two",
               context_length: 1000,
               prompt_price: two,
               completion_price: zero
             }
           ] = Nano.OpenRouter.models()

    assert_in_delta two, 2.0, 1.0e-9
    assert zero == 0.0

    # The second call is answered from the cache.
    Fake.models([])
    assert [%{id: "a/one"}, %{id: "b/two"}] = Nano.OpenRouter.models()
  end

  test "models/0: each model's reasoning levels, lowest first, and its default" do
    # Reasoning blocks as OpenRouter lists them (2026-10-07).
    Fake.models([
      %{
        "id" => "a/optional",
        "reasoning" => %{
          "mandatory" => false,
          "default_enabled" => true,
          "supported_efforts" => ["max", "high", "low"],
          "default_effort" => "high"
        }
      },
      %{
        "id" => "b/mandatory",
        "reasoning" => %{
          "mandatory" => true,
          "supported_efforts" => ["max", "xhigh", "high", "medium", "low"],
          "default_effort" => "medium"
        }
      },
      %{"id" => "c/any", "reasoning" => %{"mandatory" => false, "supported_efforts" => []}},
      %{"id" => "d/none-listed", "reasoning" => %{"supported_efforts" => ["none", "minimal"]}},
      %{"id" => "e/no-reasoning"}
    ])

    assert [
             %{reasoning_levels: ~w(off low high max), default_reasoning: "high"},
             %{reasoning_levels: ~w(low medium high xhigh max), default_reasoning: "medium"},
             %{
               reasoning_levels: ~w(off minimal low medium high xhigh max),
               default_reasoning: "off"
             },
             %{reasoning_levels: ~w(off minimal), default_reasoning: "off"},
             %{reasoning_levels: ["off"], default_reasoning: "off"}
           ] = Nano.OpenRouter.models()
  end

  test "models/0 returns [] when the request fails or nothing answers" do
    Fake.models(503)
    assert Nano.OpenRouter.models() == []

    :persistent_term.erase({Nano.OpenRouter, :models})
    saved = Application.get_env(:nano, :openrouter_base_url)
    Application.put_env(:nano, :openrouter_base_url, "http://127.0.0.1:1/unset")
    on_exit(fn -> Application.put_env(:nano, :openrouter_base_url, saved) end)
    assert Nano.OpenRouter.models() == []
  end
end
